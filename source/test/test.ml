(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Core
open OUnit2
open Analysis
open Ast
open Pyre
open PyreParser
open Statement

let initialize () =
  Log.GlobalState.initialize_for_tests ();
  Memory.initialize_for_tests ();
  Statistics.disable ()


let () = initialize ()

let trim_extra_indentation source =
  let is_non_empty line = not (String.for_all ~f:Char.is_whitespace line) in
  let minimum_indent lines =
    let indent line = String.to_list line |> List.take_while ~f:Char.is_whitespace |> List.length in
    List.filter lines ~f:is_non_empty
    |> List.map ~f:indent
    |> List.fold ~init:Int.max_value ~f:Int.min
  in
  let strip_line minimum_indent line =
    if not (is_non_empty line) then
      line
    else
      String.slice line minimum_indent (String.length line)
  in
  let strip_lines minimum_indent = List.map ~f:(strip_line minimum_indent) in
  let lines = String.rstrip source |> String.split ~on:'\n' in
  let minimum_indent = minimum_indent lines in
  strip_lines minimum_indent lines |> String.concat ~sep:"\n"


let rec coerce_special_methods { Node.location; value } =
  (* Turn all explicit dunder attribute accesses to be special methods accesses. *)
  let open Expression in
  match value with
  | Expression.Name (Name.Attribute ({ base; attribute; _ } as name))
    when String.is_prefix ~prefix:"__" attribute && String.is_suffix ~suffix:"__" attribute ->
      {
        Node.location;
        value =
          Expression.Name
            (Name.Attribute { name with base = coerce_special_methods base; special = true });
      }
  | Call { callee; arguments } ->
      { Node.location; value = Call { callee = coerce_special_methods callee; arguments } }
  | _ -> { Node.location; value }


let coerce_special_methods_source source =
  let module Transform = Transform.Make (struct
    include Transform.Identity

    type t = unit

    let transform_expression_children _ _ = true

    let expression _ expression = coerce_special_methods expression
  end)
  in
  Transform.transform () source |> Transform.source


let run tests =
  let rec bracket test =
    let bracket_test test context =
      initialize ();
      test context;
      Unix.unsetenv "HH_SERVER_DAEMON_PARAM";
      Unix.unsetenv "HH_SERVER_DAEMON"
    in
    match test with
    | OUnitTest.TestLabel (name, test) -> OUnitTest.TestLabel (name, bracket test)
    | OUnitTest.TestList tests -> OUnitTest.TestList (List.map tests ~f:bracket)
    | OUnitTest.TestCase (length, f) -> OUnitTest.TestCase (length, bracket_test f)
  in
  tests |> bracket |> run_test_tt_main


let parse_untrimmed ?(handle = "") ?(silent = false) ?(coerce_special_methods = false) source =
  let buffer = Lexing.from_string (source ^ "\n") in
  buffer.Lexing.lex_curr_p <- { buffer.Lexing.lex_curr_p with Lexing.pos_fname = handle };
  try
    let source =
      let state = Lexer.State.initial () in
      let metadata =
        let qualifier = SourcePath.qualifier_of_relative handle in
        Source.Metadata.parse ~qualifier (String.split source ~on:'\n')
      in
      Source.create ~metadata ~relative:handle (Generator.parse (Lexer.read state) buffer)
    in
    let coerce_special_methods =
      if coerce_special_methods then coerce_special_methods_source else Fn.id
    in
    source |> coerce_special_methods
  with
  | Pyre.ParserError _
  | Generator.Error ->
      let location =
        Location.create ~start:buffer.Lexing.lex_curr_p ~stop:buffer.Lexing.lex_curr_p
      in
      let line = location.Location.start.Location.line - 1
      and column = location.Location.start.Location.column in
      let header = Format.asprintf "\nCould not parse test at %a" Location.pp location in
      let indicator = if column > 0 then String.make (column - 1) ' ' ^ "^" else "^" in
      let error =
        match List.nth (String.split source ~on:'\n') line with
        | Some line -> Format.asprintf "%s:\n  %s\n  %s" header line indicator
        | None -> header ^ "."
      in
      if not silent then
        Printf.printf "%s" error;
      failwith "Could not parse test"


let parse ?(handle = "") ?(coerce_special_methods = false) source =
  trim_extra_indentation source |> parse_untrimmed ~handle ~coerce_special_methods


let parse_single_statement ?(preprocess = false) ?(coerce_special_methods = false) ?handle source =
  let source =
    if preprocess then
      Preprocessing.preprocess (parse ?handle ~coerce_special_methods source)
    else
      parse ~coerce_special_methods source
  in
  match source with
  | { Source.statements = [statement]; _ } -> statement
  | _ -> failwith "Could not parse single statement"


let parse_last_statement source =
  match parse source with
  | { Source.statements; _ } when List.length statements > 0 -> List.last_exn statements
  | _ -> failwith "Could not parse last statement"


let parse_single_define source =
  match parse_single_statement source with
  | { Node.value = Statement.Define define; _ } -> define
  | _ -> failwith "Could not parse single define"


let parse_single_class source =
  match parse_single_statement source with
  | { Node.value = Statement.Class definition; _ } -> definition
  | _ -> failwith "Could not parse single class"


let parse_single_expression ?(preprocess = false) ?(coerce_special_methods = false) source =
  match parse_single_statement ~preprocess ~coerce_special_methods source with
  | { Node.value = Statement.Expression expression; _ } -> expression
  | _ -> failwith "Could not parse single expression."


let parse_single_call ?(preprocess = false) source =
  match parse_single_expression ~preprocess source with
  | { Node.value = Call call; _ } -> call
  | _ -> failwith "Could not parse single call"


let parse_callable ?name ?(aliases = Type.empty_aliases) callable =
  let callable = parse_single_expression callable |> Type.create ~aliases in
  match name, callable with
  | Some name, Type.Callable callable ->
      Type.Callable { callable with Type.Callable.kind = Named name }
  | ( Some name,
      Type.Parametric
        { name = "BoundMethod"; parameters = [Single (Callable callable); Single self_type] } ) ->
      Type.parametric
        "BoundMethod"
        [Single (Callable { callable with Type.Callable.kind = Named name }); Single self_type]
  | _ -> callable


let diff ~print format (left, right) =
  let escape string =
    String.substr_replace_all string ~pattern:"\"" ~with_:"\\\""
    |> String.substr_replace_all ~pattern:"'" ~with_:"\\\""
    |> String.substr_replace_all ~pattern:"`" ~with_:"?"
    |> String.substr_replace_all ~pattern:"$" ~with_:"@"
  in
  let input =
    Format.sprintf
      "bash -c \"diff -u <(echo '%s') <(echo '%s')\""
      (escape (Format.asprintf "%a" print left))
      (escape (Format.asprintf "%a" print right))
    |> Unix.open_process_in
  in
  Format.fprintf format "\n%s" (In_channel.input_all input);
  In_channel.close input


let map_printer ~key_pp ~data_pp map =
  let to_string (key, data) = Format.asprintf "    %a -> %a" key_pp key data_pp data in
  Map.to_alist map |> List.map ~f:to_string |> String.concat ~sep:"\n"


let show_optional show optional = optional >>| show |> Option.value ~default:"None"

let collect_nodes_as_strings source =
  let module Collector = Visit.NodeCollector (struct
    type t = string * Location.t

    let predicate = function
      | Visit.Expression expression ->
          Some
            (Transform.sanitize_expression expression |> Expression.show, Node.location expression)
      | Visit.Statement _ -> None
      | Visit.Identifier { Node.value; location } -> Some (Identifier.sanitized value, location)
      | Visit.Parameter { Node.value = { Expression.Parameter.name; _ }; location } ->
          Some (Identifier.sanitized name, location)
      | Visit.Reference { Node.value; location } -> Some (Reference.show value, location)
      | Visit.Substring { Node.value; location } -> Some (Expression.Substring.show value, location)
      | Visit.Generator _ -> None
  end)
  in
  Collector.collect source


let node ~start:(start_line, start_column) ~stop:(stop_line, stop_column) =
  let location =
    {
      Location.start = { Location.line = start_line; Location.column = start_column };
      stop = { Location.line = stop_line; Location.column = stop_column };
    }
  in
  Node.create ~location


let assert_source_equal ?(location_insensitive = false) left right =
  let metadata = Source.Metadata.create_for_testing () in
  let left = { left with Source.metadata } in
  let right = { right with Source.metadata } in
  let cmp =
    if location_insensitive then
      fun left right ->
    Source.equal { left with statements = [] } { right with statements = [] }
    && List.equal
         (fun left right -> Statement.location_insensitive_compare left right = 0)
         left.statements
         right.statements
    else
      Source.equal
  in
  assert_equal
    ~cmp
    ~printer:(fun source -> Format.asprintf "%a" Source.pp source)
    ~pp_diff:(diff ~print:Source.pp)
    left
    right


let assert_source_equal_with_locations expected actual =
  let equal_statement left right = Int.equal 0 (Statement.compare left right) in
  let compare_sources expected actual =
    let { Source.statements = left; _ } = expected in
    let { Source.statements = right; _ } = actual in
    List.equal equal_statement left right
  in
  let pp_with_locations format { Source.statements; _ } =
    let rec print_statement ~prefix statement =
      let indented_prefix = prefix ^ "  " in
      let pp_nested_expressions format statement =
        let print_expression (node_string, location) =
          let add_indentation expression_string =
            let indent expression_string =
              String.split ~on:'\n' expression_string |> String.concat ~sep:("\n" ^ indented_prefix)
            in
            indented_prefix ^ indent expression_string
          in
          Format.fprintf
            format
            "%s -> (%a)\n"
            (node_string |> add_indentation)
            Location.pp_line_and_column
            location
        in
        collect_nodes_as_strings (Source.create [statement]) |> List.iter ~f:print_expression
      in
      let pp_nested_statements _ statement =
        let immediate_children =
          match Node.value statement with
          | Statement.Class { Class.body; _ }
          | Define { Define.body; _ }
          | With { With.body; _ } ->
              body
          | For { For.body; orelse; _ }
          | If { If.body; orelse; _ }
          | While { While.body; orelse; _ } ->
              body @ orelse
          | Try { Try.body; handlers; orelse; finally } ->
              let handlers =
                let get_handler_body sofar { Try.Handler.body; _ } = body @ sofar in
                List.fold ~init:[] ~f:get_handler_body handlers
              in
              body @ handlers @ orelse @ finally
          | _ -> []
        in
        List.iter ~f:(print_statement ~prefix:indented_prefix) immediate_children
      in
      Format.fprintf
        format
        "%s%a -> (%a)\n%sNested Expressions:\n%a%sNested Statements:\n%a"
        prefix
        pp
        statement
        Location.pp_line_and_column
        statement.Node.location
        indented_prefix
        pp_nested_expressions
        statement
        indented_prefix
        pp_nested_statements
        statement
    in
    List.iter statements ~f:(print_statement ~prefix:"")
  in
  let pp_diff_with_locations format (expected, actual) =
    (* Don't diff location discrepancies due to Location.any. *)
    let create_separate_blocks pp_string =
      pp_string |> String.split ~on:'\n' |> String.concat ~sep:"\n\n"
    in
    let expected_string =
      Format.asprintf "%a" pp_with_locations expected |> create_separate_blocks
    in
    let actual_string = Format.asprintf "%a" pp_with_locations actual |> create_separate_blocks in
    let collect_non_anys difference =
      let matches regex line = Str.string_match (Str.regexp regex) line 0 in
      let is_removed_any = matches "-.*\\(-1:-1--1:-1\\)" in
      let is_difference line = matches "-.*" line || matches "+.*" line in
      let rec collect_non_anys collected = function
        | removed :: _ :: rest when is_removed_any removed -> collect_non_anys collected rest
        | line :: rest when is_difference line -> collect_non_anys (line :: collected) rest
        | _ :: rest -> collect_non_anys collected rest
        | _ -> collected
      in
      collect_non_anys [] difference |> List.rev
    in
    Format.asprintf "%a" (diff ~print:String.pp) (expected_string, actual_string)
    |> String.split ~on:'\n'
    |> collect_non_anys
    |> String.concat ~sep:"\n"
    |> Format.fprintf format "%s"
  in
  assert_equal
    ~cmp:compare_sources
    ~printer:(fun source -> Format.asprintf "\n%a" pp_with_locations source)
    ~pp_diff:pp_diff_with_locations
    expected
    actual


let assert_type_equal = assert_equal ~printer:Type.show ~cmp:Type.equal

(* Expression helpers. *)
let ( ~+ ) value = Node.create_with_default_location value

let ( ! ) name = +Expression.Expression.Name (Expression.create_name ~location:Location.any name)

let ( !! ) name =
  +Statement.Expression
     (+Expression.Expression.Name (Expression.create_name ~location:Location.any name))


let ( !& ) name = Reference.create name

(* Assertion helpers. *)
let assert_true = assert_bool ""

let assert_false test = assert_bool "" (not test)

let assert_is_some test = assert_true (Option.is_some test)

let assert_is_none test = assert_true (Option.is_none test)

let assert_unreached () = assert_true false

(* Override `OUnit`s functions the return absolute paths. *)
let bracket_tmpdir ?suffix context = bracket_tmpdir ?suffix context |> Filename.realpath

let bracket_tmpfile ?suffix context =
  bracket_tmpfile ?suffix context |> fun (filename, channel) -> Filename.realpath filename, channel


let typeshed_stubs ?(include_helper_builtins = true) () =
  let builtins =
    let helper_builtin_stubs =
      {|
        import typing

        def not_annotated(input = ...): ...

        def expect_int(i: int) -> None: ...
        def to_int(x: Any) -> int: ...
        def int_to_str(i: int) -> str: ...
        def str_to_int(i: str) -> int: ...
        def optional_str_to_int(i: Optional[str]) -> int: ...
        def int_to_bool(i: int) -> bool: ...
        def int_to_int(i: int) -> int: pass
        def str_float_to_int(i: str, f: float) -> int: ...
        def str_float_tuple_to_int(t: Tuple[str, float]) -> int: ...
        def nested_tuple_to_int(t: Tuple[Tuple[str, float], float]) -> int: ...
        def return_tuple() -> Tuple[int, int]: ...
        def unknown_to_int(i) -> int: ...
        def star_int_to_int( *args, x: int) -> int: ...
        def takes_iterable(x: Iterable[_T]) -> None: ...
        def awaitable_int() -> typing.Awaitable[int]: ...
        def condition() -> bool: ...

        def __test_sink(arg: Any) -> None: ...
        def __test_source() -> Any: ...
        class TestCallableTarget:
          def __call__(self) -> int: ...
        def to_callable_target(f: typing.Callable[..., Any]) -> TestCallableTarget: ...
        def __tito( *x: Any, **kw: Any) -> Any: ...
        __global_sink: Any
        def copy(obj: object) -> object: ...
        def pyre_dump() -> None: ...
        def __user_controlled() -> Any: ...
        class ClassWithSinkAttribute():
          attribute: Any = ...

        class IsAwaitable(typing.Awaitable[int]): pass

        def identity(x: _T) -> _T: ...
        _VR = TypeVar("_VR", str, int)
        def variable_restricted_identity(x: _VR) -> _VR: pass

        def returns_undefined()->Undefined: ...
        class Spooky:
          def undefined(self)->Undefined: ...

        class Attributes:
          int_attribute: int

        class OtherAttributes:
          int_attribute: int
          str_attribute: str

        class A: ...
        class B(A): ...
        class C(A): ...
        class D(B,C): ...
        class obj():
          @staticmethod
          def static_int_to_str(i: int) -> str: ...
        class _PathLike(typing.Generic[typing.AnyStr]): ...
      |}
    in
    let builtin_stubs =
      {|
        from typing import (
          TypeVar, Iterator, Iterable, NoReturn, overload, Container,
          Sequence, MutableSequence, Mapping, MutableMapping, Tuple, List, Any,
          Dict, Callable, Generic, Set, AbstractSet, FrozenSet, MutableSet, Sized,
          Reversible, SupportsInt, SupportsFloat, SupportsAbs,
          SupportsComplex, SupportsRound, IO, BinaryIO, Union, final,
          ItemsView, KeysView, ValuesView, ByteString, Optional, AnyStr, Type, Text,
        )
        from pyre_extensions import Add, Multiply, Divide
        from typing_extensions import Literal

        _T = TypeVar('_T')
        _T_co = TypeVar('_T_co', covariant=True)
        _S = TypeVar('_S')

        class type:
          __name__: str = ...
          def __call__(self, *args: Any, **kwargs: Any) -> Any: ...
          @overload
          def __init__(self, o: object) -> None: ...
          @overload
          def __init__(self, name: str, bases: Tuple[type, ...], dict: Dict[str, Any]) -> None: ...
          @overload
          def __new__(cls, o: object) -> type: ...
          @overload
          def __new__(cls, name: str, bases: Tuple[type, ...], namespace: Dict[str, Any]) -> type: ...

        class object():
          __doc__: str
          __module__: str
          @property
          def __class__(self: _T) -> Type[_T]: ...
          def __init__(self) -> None: ...
          def __new__(cls) -> Any: ...
          def __setattr__(self, name: str, value: Any) -> None: ...
          def __eq__(self, o: object) -> bool: ...
          def __ne__(self, o: object) -> bool: ...
          def __str__(self) -> str: ...
          def __repr__(self) -> str: ...
          def __hash__(self) -> int: ...
          def __format__(self, format_spec: str) -> str: ...
          def __getattribute__(self, name: str) -> Any: ...
          def __delattr__(self, name: str) -> None: ...
          def __sizeof__(self) -> int: ...
          def __reduce__(self) -> tuple: ...

        class ellipsis: ...
        Ellipsis: ellipsis

        class BaseException(object):
          def __str__(self) -> str: ...
          def __repr__(self) -> str: ...
        class Exception(BaseException): ...

        class slice:
          @overload
          def __init__(self, stop: Optional[int]) -> None: ...
          @overload
          def __init__(
            self,
            start: Optional[int],
            stop: Optional[int],
            step: Optional[int] = ...
          ) -> None: ...
          def indices(self, len: int) -> Tuple[int, int, int]: ...

        class range(Sequence[int]):
          start: int
          stop: int
          step: int
          @overload
          def __init__(self, stop: int) -> None: ...
          @overload
          def __init__(self, start: int, stop: int, step: int = ...) -> None: ...
          def count(self, value: int) -> int: ...
          def index(self, value: int, start: int = ..., stop: Optional[int] = ...) -> int: ...
          def __len__(self) -> int: ...
          def __contains__(self, o: object) -> bool: ...
          def __iter__(self) -> Iterator[int]: ...
          @overload
          def __getitem__(self, i: int) -> int: ...
          @overload
          def __getitem__(self, s: slice) -> range: ...
          def __repr__(self) -> str: ...
          def __reversed__(self) -> Iterator[int]: ...

        class super:
           @overload
           def __init__(self, t: Any, obj: Any) -> None: ...
           @overload
           def __init__(self, t: Any) -> None: ...
           @overload
           def __init__(self) -> None: ...

        class bool(): ...

        class bytes(): ...

        class float():
          def __add__(self, other) -> float: ...
          def __radd__(self, other: float) -> float: ...
          def __mul__(self, other: float) -> float: ...
          def __rmul__(self, other: int) -> float: ...
          def __neg__(self) -> float: ...
          def __abs__(self) -> float: ...
          def __round__(self) -> int: ...
          def __lt__(self, x: float) -> bool: ...
          def __le__(self, x: float) -> bool: ...
          def __gt__(self, x: float) -> bool: ...
          def __ge__(self, x: float) -> bool: ...

        N1 = TypeVar("N1", bound=int)
        N2 = TypeVar("N2", bound=int)

        class int:
          @overload
          def __init__(self, x: Union[Text, bytes, SupportsInt] = ...) -> None: ...
          @overload
          def __init__(self, x: Union[Text, bytes, bytearray], base: int) -> None: ...
          @property
          def real(self) -> int: ...
          @property
          def imag(self) -> int: ...
          @property
          def numerator(self) -> int: ...
          @property
          def denominator(self) -> int: ...
          def conjugate(self) -> int: ...
          def __add__(self: N1, x: N2) -> Add[N1, N2]: ...
          def __sub__(self: N1, x: N2) -> Add[N1, Multiply[Literal[-1], N2]]: ...
          def __mul__(self: N1, x: N2) -> Multiply[N1, N2]: ...
          def __floordiv__(self: N1, x: N2) -> Divide[N1, N2]: ...
          if sys.version_info < (3,):
              def __div__(self, x: int) -> int: ...
          def __truediv__(self, x: int) -> float: ...
          def __mod__(self, x: int) -> int: ...
          def __divmod__(self, x: int) -> Tuple[int, int]: ...
          def __radd__(self, x: int) -> int: ...
          def __rsub__(self, x: int) -> int: ...
          def __rmul__(self, x: int) -> int: ...
          def __rfloordiv__(self, x: int) -> int: ...
          if sys.version_info < (3,):
              def __rdiv__(self, x: int) -> int: ...
          def __rtruediv__(self, x: int) -> float: ...
          def __rmod__(self, x: int) -> int: ...
          def __rdivmod__(self, x: int) -> Tuple[int, int]: ...
          def __pow__(self, __x: int, __modulo: Optional[int] = ...) -> Any: ...  # Return type can be int or float, depending on x.
          def __rpow__(self, x: int) -> Any: ...
          def __and__(self, n: int) -> int: ...
          def __or__(self, n: int) -> int: ...
          def __xor__(self, n: int) -> int: ...
          def __lshift__(self, n: int) -> int: ...
          def __rshift__(self, n: int) -> int: ...
          def __rand__(self, n: int) -> int: ...
          def __ror__(self, n: int) -> int: ...
          def __rxor__(self, n: int) -> int: ...
          def __rlshift__(self, n: int) -> int: ...
          def __rrshift__(self, n: int) -> int: ...
          def __neg__(self) -> int: ...
          def __pos__(self) -> int: ...
          def __invert__(self) -> int: ...
          def __trunc__(self) -> int: ...
          def __getnewargs__(self) -> Tuple[int]: ...
          def __eq__(self, x: object) -> bool: ...
          def __ne__(self, x: object) -> bool: ...
          def __lt__(self, x: int) -> bool: ...
          def __le__(self, x: int) -> bool: ...
          def __gt__(self, x: int) -> bool: ...
          def __ge__(self, x: int) -> bool: ...
          def __str__(self) -> str: ...
          def __float__(self) -> float: ...
          def __int__(self) -> int: ...
          def __abs__(self) -> int: ...
          def __hash__(self) -> int: ...
          def __floor__(self) -> int: ...
          def __ceil__(self) -> int: ...

        class complex():
          def __radd__(self, other: int) -> int: ...

        class str(Sequence[str]):
          @overload
          def __init__(self, o: object = ...) -> None: ...
          @overload
          def __init__(self, o: bytes, encoding: str = ..., errors: str = ...) -> None: ...
          def format(self, *args) -> str: pass
          def lower(self) -> str: pass
          def upper(self) -> str: ...
          def substr(self, index: int) -> str: pass
          def join(self, iterable: Iterable[str]) -> str: ...
          def __lt__(self, other: int) -> float: ...
          def __ne__(self, other) -> int: ...
          def __add__(self, other: str) -> str: ...
          def __pos__(self) -> float: ...
          def __repr__(self) -> float: ...
          def __str__(self) -> str: ...
          def __getitem__(self, i: Union[int, slice]) -> str: ...
          def __iter__(self) -> Iterator[str]: ...
          def __eq__(self, x: object) -> bool: ...
          def __len__(self) -> int: ...

        class tuple(Sequence[_T_co], Sized, Generic[_T_co]):
          def __init__(self, a: List[_T_co]): ...
          def __len__(self) -> int: ...
          def tuple_method(self, a: int): ...
          def __lt__(self, x: Tuple[_T_co, ...]) -> bool: ...
          def __le__(self, x: Tuple[_T_co, ...]) -> bool: ...
          def __gt__(self, x: Tuple[_T_co, ...]) -> bool: ...
          def __ge__(self, x: Tuple[_T_co, ...]) -> bool: ...
          def __add__(self, x: Tuple[_T_co, ...]) -> Tuple[_T_co, ...]: ...
          def __mul__(self, n: int) -> Tuple[_T_co, ...]: ...
          def __rmul__(self, n: int) -> Tuple[_T_co, ...]: ...
          @overload
          def __getitem__(self, x: int) -> _T_co: ...
          @overload
          def __getitem__(self, x: slice) -> Tuple[_T_co, ...]: ...

        class dict(MutableMapping[_T, _S], Generic[_T, _S]):
          @overload
          def __init__(self, **kwargs: _S) -> None: ...
          @overload
          def __init__(self, map: Mapping[_T, _S], **kwargs: _S) -> None: ...
          @overload
          def __init__(self, iterable: Iterable[Tuple[_T, _S]], **kwargs: _S) -> None:
            ...
          def add_key(self, key: _T) -> None: pass
          def add_value(self, value: _S) -> None: pass
          def add_both(self, key: _T, value: _S) -> None: pass
          def items(self) -> Iterable[Tuple[_T, _S]]: pass
          def __delitem__(self, v: _T) -> None: ...
          def __getitem__(self, k: _T) -> _S: ...
          def __setitem__(self, k: _T, v: _S) -> None: ...
          @overload
          def get(self, k: _T) -> Optional[_S]: ...
          @overload
          def get(self, k: _T, default: _S) -> _S: ...
          @overload
          def update(self, __m: Mapping[_T, _S], **kwargs: _S) -> None: ...
          @overload
          def update(self, __m: Iterable[Tuple[_T, _S]], **kwargs: _S) -> None: ...
          @overload
          def update(self, **kwargs: _S) -> None: ...

          def __len__(self) -> int: ...

        class list(Sequence[_T], Generic[_T]):
          @overload
          def __init__(self) -> None: ...
          @overload
          def __init__(self, iterable: Iterable[_T]) -> None: ...

          def __add__(self, x: list[_T]) -> list[_T]: ...
          def __iter__(self) -> Iterator[_T]: ...
          def append(self, element: _T) -> None: ...
          @overload
          def __getitem__(self, i: int) -> _T: ...
          @overload
          def __getitem__(self, s: slice) -> List[_T]: ...
          def __contains__(self, o: object) -> bool: ...

          def __len__(self) -> int: ...

        class set(Iterable[_T], Generic[_T]):
          def __init__(self, iterable: Iterable[_T] = ...) -> None: ...

        def len(o: Sized) -> int: ...
        def isinstance(
          a: object,
          b: Union[type, Tuple[Union[type, Tuple], ...]]
        ) -> bool: ...
        def sum(iterable: Iterable[_T]) -> Union[_T, int]: ...

        def eval(arg: str) -> None: ...

        @overload
        def filter(__function: None,
                   __iterable: Iterable[Optional[_T]]
        ) -> Iterator[_T]: ...

        @overload
        def filter(__function: Callable[[_T], Any],
                   __iterable: Iterable[_T]
        ) -> Iterator[_T]: ...

        def getattr(
          o: object,
          name: str,
          default: Any = ...,
        ) -> Any: ...

        def all(i: Iterable[_T]) -> bool: ...
        _T1 = TypeVar("_T1")
        _T2 = TypeVar("_T2")
        _T3 = TypeVar("_T3")
        _T4 = TypeVar("_T4")
        _T5 = TypeVar("_T5")
        @overload
        def map(__func: Callable[[_T1], _S],
                __iter1: Iterable[_T1]
        ) -> Iterator[_S]:
            ...
        @overload
        def map(
            __func: Callable[[_T1, _T2], _S],
            __iter1: Iterable[_T1],
            __iter2: Iterable[_T2]
        ) -> Iterator[_S]:
            ...
        @overload
        def map(
            __func: Callable[[_T1, _T2, _T3], _S],
            __iter1: Iterable[_T1],
            __iter2: Iterable[_T2],
            __iter3: Iterable[_T3],
        ) -> Iterator[_S]:
            ...
        @overload
        def map(
            __func: Callable[[_T1, _T2, _T3, _T4], _S],
            __iter1: Iterable[_T1],
            __iter2: Iterable[_T2],
            __iter3: Iterable[_T3],
            __iter4: Iterable[_T4],
        ) -> Iterator[_S]:
            ...
        @overload
        def map(
            __func: Callable[[_T1, _T2, _T3, _T4, _T5], _S],
            __iter1: Iterable[_T1],
            __iter2: Iterable[_T2],
            __iter3: Iterable[_T3],
            __iter4: Iterable[_T4],
            __iter5: Iterable[_T5],
        ) -> Iterator[_S]:
            ...
        @overload
        def map(
            __func: Callable[..., _S],
            __iter1: Iterable[Any],
            __iter2: Iterable[Any],
            __iter3: Iterable[Any],
            __iter4: Iterable[Any],
            __iter5: Iterable[Any],
            __iter6: Iterable[Any],
            *__iterables: Iterable[Any],
        ) -> Iterator[_S]:
            ...

        class property:
           def getter(self, fget: Any) -> Any: ...
           def setter(self, fset: Any) -> Any: ...
           def deletler(self, fdel: Any) -> Any: ...

        class staticmethod:
           def __init__(self, f: Callable[..., Any]): ...

        class classmethod:
           def __init__(self, f: Callable[..., Any]): ...

        def callable(__o: object) -> bool: ...

        if sys.version_info >= (3,):
          class _Writer(Protocol):
              def write(self, __s: str) -> Any: ...
          def print(
              *values: object, sep: Optional[Text] = ..., end: Optional[Text] = ..., file: Optional[_Writer] = ..., flush: bool = ...
          ) -> None: ...
        else:
          class _Writer(Protocol):
              def write(self, __s: Any) -> Any: ...
          # This is only available after from __future__ import print_function.
          def print( *values: object, sep: Optional[Text] = ..., end: Optional[Text] = ..., file: Optional[_Writer] = ...) -> None: ...

        class _NotImplementedType(Any):  # type: ignore
            # A little weird, but typing the __call__ as NotImplemented makes the error message
            # for NotImplemented() much better
            __call__: NotImplemented  # type: ignore

        NotImplemented: _NotImplementedType

      |}
    in
    if include_helper_builtins then
      String.concat ~sep:"\n" [String.rstrip builtin_stubs; helper_builtin_stubs]
    else
      builtin_stubs
  in
  let sqlalchemy_stubs =
    [
      (* These are simplified versions of the SQLAlchemy stubs. *)
      ( "sqlalchemy/ext/declarative/__init__.pyi",
        {|
            from .api import (
                declarative_base as declarative_base,
                DeclarativeMeta as DeclarativeMeta,
            )
          |}
      );
      ( "sqlalchemy/ext/declarative/api.pyi",
        {|
            def declarative_base(bind: Optional[Any] = ..., metadata: Optional[Any] = ...,
                                 mapper: Optional[Any] = ..., cls: Any = ..., name: str = ...,
                                 constructor: Any = ..., class_registry: Optional[Any] = ...,
                                 metaclass: Any = ...): ...

            class DeclarativeMeta(type):
                def __init__(cls, classname, bases, dict_) -> None: ...
                def __setattr__(cls, key, value): ...
          |}
      );
      ( "sqlalchemy/__init__.pyi",
        {|
            from typing import Generic, Optional, Text as typing_Text, Type, TypeVar, final, overload
            from typing_extensions import Literal
            _T_co = TypeVar('_T_co', covariant=True)
            _T = TypeVar('_T')
            class TypeEngine(Generic[_T_co]): ...
            class Integer(TypeEngine[int]): ...
            class String(TypeEngine[str]): ...

            @final
            class Column(Generic[_T]):
              @overload
              def __new__(
                cls, type_: TypeEngine[_T],
              ) -> Column[Optional[_T]]: ...
              @overload
              def __new__(
                cls, type_: TypeEngine[_T],
                primary_key: Literal[True] = ...
              ) -> Column[_T]: ...
              @overload
              def __new__(
                cls, type_: TypeEngine[_T],
                primary_key: Literal[False] = ...
              ) -> Column[Optional[_T]]: ...
              def __new__(
                cls, type_: TypeEngine[_T],
                primary_key: bool = ...
              ) -> Union[Column[_T], Column[Optional[_T]]]: ...

              @overload
              def __get__(self, instance: None, owner: Any) -> Column[_T]: ...
              @overload
              def __get__(self, instance: object, owner: Any) -> _T: ...
          |}
      );
      ( "sqlalchemy/sql/schema.pyi",
        {|
            class Table: ...
            class MetaData: ...
        |} );
    ]
  in
  let sqlalchemy_1_4_stubs =
    [
      "sqlalchemy_1_4/__init__.pyi", {|
      from ..sqlalchemy import *
    |};
      ( "sqlalchemy_1_4/ext/declarative/__init__.pyi",
        {|
            from .api import (
                declarative_base as declarative_base,
                DeclarativeMeta as DeclarativeMeta,
            )
          |}
      );
      ( "sqlalchemy_1_4/ext/declarative/api.pyi",
        {|
            def declarative_base(bind: Optional[Any] = ..., metadata: Optional[Any] = ...,
                                 mapper: Optional[Any] = ..., cls: Any = ..., name: str = ...,
                                 constructor: Any = ..., class_registry: Optional[Any] = ...,
                                 metaclass: Any = ...): ...

            class DeclarativeMeta(type):
                def __init__(cls, classname, bases, dict_) -> None: ...
                def __setattr__(cls, key, value): ...
        |}
      );
    ]
  in
  [
    ( "sys.py",
      {|
        from typing import NoReturn
        def exit(code: int) -> NoReturn: ...
    |} );
    ( "hashlib.pyi",
      {|
        _DataType = typing.Union[int, str]
        class _Hash:
          digest_size: int
        def md5(input: _DataType) -> _Hash: ...
        |}
    );
    ( "typing.pyi",
      {|
        from abc import ABCMeta, abstractmethod
        import collections
        class _SpecialForm:
          def __getitem__(self, typeargs: Any) -> Any: ...

        TypeVar = object()
        Annotated = TypeAlias(object)
        List = TypeAlias(object)
        Dict = TypeAlias(object)
        Optional: _SpecialForm = ...
        Union: _SpecialForm = ...
        Any = object()
        overload = object()
        if sys.version_info >= (3, 8):
          Final: _SpecialForm = ...
          _F = TypeVar('_F', bound=Callable[..., Any])
          def final(f: _F) -> _F: ...
          Literal: _SpecialForm = ...
          # TypedDict is a (non-subscriptable) special form.
          TypedDict: object

        Callable: _SpecialForm = ...
        Protocol: _SpecialForm = ...
        Type: _SpecialForm = ...
        Tuple: _SpecialForm = ...
        Generic: _SpecialForm = ...
        ClassVar: _SpecialForm = ...
        # TODO(T76821797): This is wrong. But it's what typeshed says
        NoReturn = Union[None]
        TypeGuard: _SpecialForm = ...

        if sys.version_info < (3, 7):
            class GenericMeta(type): ...

        if sys.version_info >= (3, 10):
          class ParamSpec:
              __name__: str
              def __init__(self, name: str) -> None: ...
          Concatenate: _SpecialForm = ...
          TypeAlias: _SpecialForm = ...
          TypeGuard: _SpecialForm = ...

        @runtime
        class Sized(Protocol, metaclass=ABCMeta):
            @abstractmethod
            def __len__(self) -> int: ...

        @runtime
        class Hashable(Protocol, metaclass=ABCMeta):
            @abstractmethod
            def __hash__(self) -> int: ...

        _T = TypeVar('_T')
        _S = TypeVar('_S')
        _KT = TypeVar('_KT')
        _VT = TypeVar('_VT')
        _T_co = TypeVar('_T_co', covariant=True)
        _V_co = TypeVar('_V_co', covariant=True)
        _KT_co = TypeVar('_KT_co', covariant=True)
        _VT_co = TypeVar('_VT_co', covariant=True)
        _T_contra = TypeVar('_T_contra', contravariant=True)

        class Iterable(Protocol[_T_co]):
          def __iter__(self) -> Iterator[_T_co]: pass
        class Iterator(Iterable[_T_co], Protocol[_T_co]):
          def __next__(self) -> _T_co: ...

        class AsyncIterable(Protocol[_T_co]):
          def __aiter__(self) -> AsyncIterator[_T_co]: ...
        class AsyncIterator(AsyncIterable[_T_co], Protocol[_T_co]):
          def __anext__(self) -> Awaitable[_T_co]: ...
          def __aiter__(self) -> AsyncIterator[_T_co]: ...
        class AsyncContextManager(Protocol[_T_co]):
            def __aenter__(self) -> Awaitable[_T_co]:
                ...

            def __aexit__(
                self,
                exc_type: Optional[Type[BaseException]],
                exc_value: Optional[BaseException],
                traceback: Optional[TracebackType],
            ) -> Awaitable[Optional[bool]]:
                ...

        if sys.version_info >= (3, 6):
          class Collection(Iterable[_T_co], Protocol[_T_co]):
            @abstractmethod
            def __len__(self) -> int: ...
          _Collection = Collection
        else:
          class _Collection(Iterable[_T_co], Protocol[_T_co]):
            @abstractmethod
            def __len__(self) -> int: ...
        class Sequence(_Collection[_T_co], Generic[_T_co]): pass

        class Generator(Generic[_T_co, _T_contra, _V_co], Iterator[_T_co]):
          pass

        class AbstractSet(_Collection[_T_co], Generic[_T_co]):
            @abstractmethod
            def __contains__(self, x: object) -> bool: ...
            # Mixin methods
            def __le__(self, s: AbstractSet[typing.Any]) -> bool: ...
            def __lt__(self, s: AbstractSet[typing.Any]) -> bool: ...
            def __gt__(self, s: AbstractSet[typing.Any]) -> bool: ...
            def __ge__(self, s: AbstractSet[typing.Any]) -> bool: ...
            def __and__(self, s: AbstractSet[typing.Any]) -> AbstractSet[_T_co]: ...
            def __or__(self, s: AbstractSet[_T]) -> AbstractSet[Union[_T_co, _T]]: ...
            def __sub__(self, s: AbstractSet[typing.Any]) -> AbstractSet[_T_co]: ...
            def __xor__(self, s: AbstractSet[_T]) -> AbstractSet[Union[_T_co, _T]]: ...
            def isdisjoint(self, s: AbstractSet[typing.Any]) -> bool: ...

        class ValuesView(MappingView, Iterable[_VT_co], Generic[_VT_co]):
            def __contains__(self, o: object) -> bool: ...
            def __iter__(self) -> Iterator[_VT_co]: ...

        class Mapping(_Collection[_KT], Generic[_KT, _VT_co]):
          @abstractmethod
          def __getitem__(self, k: _KT) -> _VT_co:
              ...
          # Mixin methods
          @overload
          def get(self, k: _KT) -> Optional[_VT_co]: ...
          @overload
          def get(self, k: _KT, default: Union[_VT_co, _T]) -> Union[_VT_co, _T]: ...
          def items(self) -> AbstractSet[Tuple[_KT, _VT_co]]: ...
          def keys(self) -> AbstractSet[_KT]: ...
          def values(self) -> ValuesView[_VT_co]: ...
          def __contains__(self, o: object) -> bool: ...

        class MutableMapping(Mapping[_KT, _VT], Generic[_KT, _VT]):
          @abstractmethod
          def __setitem__(self, k: _KT, v: _VT) -> None: ...
          @abstractmethod
          def __delitem__(self, v: _KT) -> None: ...

        class Awaitable(Protocol[_T_co]):
          def __await__(self) -> Generator[Any, None, _T_co]: ...
        class Coroutine(Awaitable[_V_co], Generic[_T_co, _T_contra, _V_co]): pass

        class AsyncGenerator(AsyncIterator[_T_co], Generic[_T_co, _T_contra]):
            @abstractmethod
            def __anext__(self) -> Awaitable[_T_co]:
                ...
            @abstractmethod
            def __aiter__(self) -> AsyncGenerator[_T_co, _T_contra]:
                ...

        @overload
        def cast(tp: Type[_T], obj: Any) -> _T: ...
        @overload
        def cast(tp: str, obj: Any) -> Any: ...

        # NamedTuple is special-cased in the type checker
        class NamedTuple(tuple):
            _field_types: collections.OrderedDict[str, Type[Any]]
            _field_defaults: Dict[str, Any] = ...
            _fields: Tuple[str, ...]
            _source: str

            def __init__(self, typename: str, fields: Iterable[Tuple[str, Any]] = ..., *,
                         verbose: bool = ..., rename: bool = ..., **kwargs: Any) -> None: ...

            @classmethod
            def _make(cls: Type[_T], iterable: Iterable[Any]) -> _T: ...

            def _asdict(self) -> collections.OrderedDict[str, Any]: ...
            def _replace(self: _T, **kwargs: Any) -> _T: ...

        class ParamSpec(list):
            args = object()
            kwargs = object()
            def __init__(self, *args: object, **kwargs: object) -> None: ...
      |}
    );
    "asyncio/coroutines.pyi", {|
        def coroutine(f: typing.Any) -> typing.Any: ...
        |};
    "asyncio/__init__.pyi", "import asyncio.coroutines";
    ( "abc.pyi",
      {|
        from typing import Type, TypeVar
        _T = TypeVar('_T')
        _FuncT = TypeVar('FuncT')
        class ABCMeta(type):
          def register(cls: ABCMeta, subclass: Type[_T]) -> Type[_T]: ...
        def abstractmethod(callable: _FuncT) -> _FuncT: ...
        class abstractproperty(property): ...
        class ABC(metaclass=ABCMeta): ...
        |}
    );
    ( "mock.pyi",
      {|
        class Base: ...
        class Mock(Base): ...
        class NonCallableMock: ...
        |}
    );
    ( "unittest/mock.pyi",
      {|
        class Base: ...
        class Mock(Base): ...
        class NonCallableMock: ...
        |}
    );
    "builtins.pyi", builtins;
    ( "django/http/__init__.pyi",
      {|
        from django.http.request import HttpRequest as HttpRequest

        class HttpResponse: ...
        class Request:
          GET: typing.Dict[str, typing.Any] = ...
          POST: typing.Dict[str, typing.Any] = ...
        |}
    );
    ( "django/http/request.pyi",
      {|
        class HttpRequest:
          GET: typing.Dict[str, typing.Any] = ...
          POST: typing.Dict[str, typing.Any] = ...
        |}
    );
    "django/__init__.pyi", "import django.http";
    ( "dataclasses.pyi",
      {|
        from typing import TypeVar, Generic, Type
        _T = TypeVar('_T')
        class InitVar(Generic[_T]): ...
        def dataclass(_cls: Type[_T]) -> Type[_T]: ...
        |}
    );
    ( "functools.pyi",
      {|
        from typing import TypeVar, Generic, Callable, Tuple, Any, Dict, Optional, Sequence
        _AnyCallable = Callable[..., Any]
        _T = TypeVar("_T")
        _S = TypeVar("_S")

        @overload
        def reduce(function: Callable[[_T, _S], _T],
                   sequence: Iterable[_S], initial: _T) -> _T: ...

        @overload
        def reduce(function: Callable[[_T, _T], _T],
                   sequence: Iterable[_T]) -> _T: ...

        class partial(Generic[_T]):
            func: Callable[..., _T]
            args: Tuple[Any, ...]
            keywords: Dict[str, Any]
            def __init__(self, func: Callable[..., _T], *args: Any, **kwargs: Any) -> None: ...
            def __call__(self, *args: Any, **kwargs: Any) -> _T: ...

        class _lru_cache_wrapper(Generic[_T]):
            __wrapped__: Callable[..., _T]
            def __call__(self, *args, **kwargs) -> _T: ...
            def cache_info(self) -> str: ...
            def cache_clear(self) -> None: ...

        def lru_cache(
          maxsize: Optional[int] = ...,
          typed: bool = ...,
        ) -> Callable[[Callable[..., _T]], _lru_cache_wrapper[_T]]:
            ...

        def wraps(
          wrapped: _AnyCallable,
          assigned: Sequence[str] = ...,
          updated: Sequence[str] = ...
        ) -> Callable[[_T], _T]: ...
       |}
    );
    ( "subprocess.pyi",
      {|
        def run(command, shell): ...
        def call(command, shell): ...
        def check_call(command, shell): ...
        def check_output(command, shell): ...
        |}
    );
    ( "multiprocessing/context.pyi",
      {|
        from typing import Optional, Callable, Tuple, Any, Mapping
        class Process:
          _start_method: Optional[str]
          def __init__(
              self,
              group: None = ...,
              target: Optional[Callable[..., Any]] = ...,
              name: Optional[str] = ...,
              args: Tuple[Any, ...] = ...,
              kwargs: Mapping[str, Any] = ...,
              *,
              daemon: Optional[bool] = ...,
          ) -> None: ...
      |}
    );
    "multiprocessing/__init__.pyi", "from multiprocessing.context import Process as Process";
    ( "enum.pyi",
      {|
        from abc import ABCMeta as ABCMeta
        from typing import Type, Mapping
        _T = typing.TypeVar('_T')
        class EnumMeta(ABCMeta):
          def __members__(self: Type[_T]) -> Mapping[str, _T]: ...
          def __iter__(self: typing.Type[_T]) -> typing.Iterator[_T]: ...
        class Enum(metaclass=EnumMeta):
          def __new__(cls: typing.Type[_T], value: object) -> _T: ...
        class IntEnum(int, Enum):
          value = ...  # type: int
        if sys.version_info >= (3, 6):
          _auto_null: typing.Any
          class auto(IntFlag):
            value: typing.Any
          class Flag(Enum):
            pass
          class IntFlag(int, Flag):  # type: ignore
            pass
        |}
    );
    "threading.pyi", {|
        class Thread:
          pass
        |};
    ( "typing_extensions.pyi",
      {|
        from typing import Final as Final, ParamSpec as ParamSpec, _SpecialForm
        Literal: _SpecialForm = ...

        TypeAlias: _SpecialForm = ...

        TypeGuard: _SpecialForm = ...
        |}
    );
    ( "collections.pyi",
      {|
        from typing import (
            TypeVar,
            Generic,
            Dict,
            overload,
            List,
            Tuple,
            Any,
            Type,
            Optional,
            Union,
            Callable,
            Mapping,
            Iterable,
            Tuple,
        )

        _DefaultDictT = TypeVar("_DefaultDictT", bound=defaultdict)
        _KT = TypeVar("_KT")
        _VT = TypeVar("_VT")


        class defaultdict(Dict[_KT, _VT], Generic[_KT, _VT]):
            default_factory = ...  # type: Optional[Callable[[], _VT]]

            @overload
            def __init__(self, **kwargs: _VT) -> None:
                ...

            @overload
            def __init__(self, default_factory: Optional[Callable[[], _VT]]) -> None:
                ...

            @overload
            def __init__(
                self, default_factory: Optional[Callable[[], _VT]], **kwargs: _VT
            ) -> None:
                ...

            @overload
            def __init__(
                self, default_factory: Optional[Callable[[], _VT]], map: Mapping[_KT, _VT]
            ) -> None:
                ...

            @overload
            def __init__(
                self,
                default_factory: Optional[Callable[[], _VT]],
                map: Mapping[_KT, _VT],
                **kwargs: _VT
            ) -> None:
                ...

            @overload
            def __init__(
                self,
                default_factory: Optional[Callable[[], _VT]],
                iterable: Iterable[Tuple[_KT, _VT]],
            ) -> None:
                ...

            @overload
            def __init__(
                self,
                default_factory: Optional[Callable[[], _VT]],
                iterable: Iterable[Tuple[_KT, _VT]],
                **kwargs: _VT
            ) -> None:
                ...

            def __missing__(self, key: _KT) -> _VT:
                ...

            def copy(self: _DefaultDictT) -> _DefaultDictT:
                ...
        |}
    );
    ( "contextlib.pyi",
      (* TODO (T41494196): Change the parameter and return type to AnyCallable *)
      {|
        from typing import Any, AsyncContextManager, AsyncIterator, Callable, Generic, Iterator, TypeVar
        _T_co = TypeVar('_T_co', covariant=True)
        _T = TypeVar('_T')
        class ContextManager(Generic[_T_co]):
          def __enter__(self) -> _T_co:
            pass
        class _GeneratorContextManager(
            contextlib.ContextManager[_T],
            Generic[_T]):
          pass
        def contextmanager(func: Callable[..., Iterator[_T]]) -> Callable[..., _GeneratorContextManager[_T]]: ...
        def asynccontextmanager(func: Callable[..., AsyncIterator[_T]]) -> Callable[..., AsyncContextManager[_T]]: ...
        |}
    );
    "taint.pyi", {|
        __global_sink: Any = ...
        |};
    ( "unittest.pyi",
      {|
        from unittest import case
        from unittest import mock
        from unittest.case import TestCase as TestCase
        curdir: str
        pardir: str
        sep: str
        |}
    );
    ( "os/__init__.pyi",
      {|
    from builtins import _PathLike as PathLike
    from . import path as path
    import typing
    environ: typing.Dict[str, str] = ...
        |}
    );
    "os/path.pyi", {|
        curdir: str
        pardir: str
        sep: str
      |};
    ( "unittest/case.pyi",
      {|
        class TestCase:
            def assertIsNotNone(self, x: Any, msg: Any = ...) -> Bool:
              ...
            def assertTrue(self, x: Any, msg: Any = ...) -> Bool:
              ...
            def assertFalse(self, x: Any, msg: Any = ...) -> Bool:
              ...
        |}
    );
    ( "pyre_extensions/__init__.pyi",
      {|
        from typing import List, Optional, Type, TypeVar
        from typing import Generic as Generic
        import type_variable_operators

        _T = TypeVar("_T")
        _A = TypeVar("_A", bound=int)
        _B = TypeVar("_B", bound=int)
        _T1 = TypeVar("_T1")
        _T2 = TypeVar("_T2")


        def none_throws(optional: Optional[_T]) -> _T: ...
        def safe_cast(new_type: Type[_T], value: Any) -> _T: ...
        def ParameterSpecification(__name: str) -> List[Type]: ...
        def ListVariadic(__name: str) -> Type: ...
        def classproperty(f: Any) -> Any: ...
        class Add(Generic[_A, _B], int): pass
        class Multiply(Generic[_A, _B], int): pass
        class Divide(Generic[_A, _B], int): pass
        _Ts = ListVariadic("_Ts")
        class Length(Generic[_Ts], int): pass
        class Product(Generic[_Ts], int): pass

        class TypeVarTuple:
            def __init__(
                self,
                name: str,
                *constraints: Type[Any],
                bound: Union[None, Type[Any], str] = ...,
                covariant: bool = ...,
                contravariant: bool = ...,
            ) -> None: ...

        class Unpack(Generic[_T]): ...
        class Broadcast(Generic[_T1, _T2]): ...
        class BroadcastError(Generic[_T1, _T2]): ...
        |}
    );
    ( "pyre_extensions/type_variable_operators.pyi",
      {|
        from typing import List, Optional, Type, TypeVar, _SpecialForm
        Map: _SpecialForm
        PositionalArgumentsOf: _SpecialForm
        KeywordArgumentsOf: _SpecialForm
        ArgumentsOf: _SpecialForm
        Concatenate: _SpecialForm
        |}
    );
    ( "numbers.pyi",
      {|
        # Stubs for numbers (Python 3.5)
        # See https://docs.python.org/2.7/library/numbers.html
        # and https://docs.python.org/3/library/numbers.html
        #
        # Note: these stubs are incomplete. The more complex type
        # signatures are currently omitted.

        from typing import Any, Optional, SupportsFloat, overload
        from abc import ABCMeta, abstractmethod
        import sys

        class Number(metaclass=ABCMeta):
            @abstractmethod
            def __hash__(self) -> int: ...

        class Complex(Number):
            @abstractmethod
            def __complex__(self) -> complex: ...
            if sys.version_info >= (3, 0):
                def __bool__(self) -> bool: ...
            else:
                def __nonzero__(self) -> bool: ...
            @property
            @abstractmethod
            def real(self): ...
            @property
            @abstractmethod
            def imag(self): ...
            @abstractmethod
            def __add__(self, other): ...
            @abstractmethod
            def __radd__(self, other): ...
            @abstractmethod
            def __neg__(self): ...
            @abstractmethod
            def __pos__(self): ...
            def __sub__(self, other): ...
            def __rsub__(self, other): ...
            @abstractmethod
            def __mul__(self, other): ...
            @abstractmethod
            def __rmul__(self, other): ...
            if sys.version_info < (3, 0):
                @abstractmethod
                def __div__(self, other): ...
                @abstractmethod
                def __rdiv__(self, other): ...
            @abstractmethod
            def __truediv__(self, other): ...
            @abstractmethod
            def __rtruediv__(self, other): ...
            @abstractmethod
            def __pow__(self, exponent): ...
            @abstractmethod
            def __rpow__(self, base): ...
            def __abs__(self): ...
            def conjugate(self): ...
            def __eq__(self, other: object) -> bool: ...
            if sys.version_info < (3, 0):
                def __ne__(self, other: object) -> bool: ...

        class Real(Complex, SupportsFloat):
            @abstractmethod
            def __float__(self) -> float: ...
            @abstractmethod
            def __trunc__(self) -> int: ...
            if sys.version_info >= (3, 0):
                @abstractmethod
                def __floor__(self) -> int: ...
                @abstractmethod
                def __ceil__(self) -> int: ...
                @abstractmethod
                @overload
                def __round__(self, ndigits: None = ...): ...
                @abstractmethod
                @overload
                def __round__(self, ndigits: int): ...
            def __divmod__(self, other): ...
            def __rdivmod__(self, other): ...
            @abstractmethod
            def __floordiv__(self, other): ...
            @abstractmethod
            def __rfloordiv__(self, other): ...
            @abstractmethod
            def __mod__(self, other): ...
            @abstractmethod
            def __rmod__(self, other): ...
            @abstractmethod
            def __lt__(self, other) -> bool: ...
            @abstractmethod
            def __le__(self, other) -> bool: ...
            def __complex__(self) -> complex: ...
            @property
            def real(self): ...
            @property
            def imag(self): ...
            def conjugate(self): ...

        class Rational(Real):
            @property
            @abstractmethod
            def numerator(self) -> int: ...
            @property
            @abstractmethod
            def denominator(self) -> int: ...
            def __float__(self) -> float: ...

        class Integral(Rational):
            if sys.version_info >= (3, 0):
                @abstractmethod
                def __int__(self) -> int: ...
            else:
                @abstractmethod
                def __long__(self) -> long: ...
            def __index__(self) -> int: ...
            @abstractmethod
            def __pow__(self, exponent, modulus: Optional[Any] = ...): ...
            @abstractmethod
            def __lshift__(self, other): ...
            @abstractmethod
            def __rlshift__(self, other): ...
            @abstractmethod
            def __rshift__(self, other): ...
            @abstractmethod
            def __rrshift__(self, other): ...
            @abstractmethod
            def __and__(self, other): ...
            @abstractmethod
            def __rand__(self, other): ...
            @abstractmethod
            def __xor__(self, other): ...
            @abstractmethod
            def __rxor__(self, other): ...
            @abstractmethod
            def __or__(self, other): ...
            @abstractmethod
            def __ror__(self, other): ...
            @abstractmethod
            def __invert__(self): ...
            def __float__(self) -> float: ...
            @property
            def numerator(self) -> int: ...
            @property
            def denominator(self) -> int: ...
        |}
    );
    ( "attr/__init__.pyi",
      {|
        from typing import Optional, TypeVar, Any, Dict
        _C = TypeVar("_C", bound=type)
        def s(
            maybe_cls: None = ...,
            these: Optional[Dict[str, Any]] = ...,
            repr_ns: Optional[str] = ...,
            repr: bool = ...,
            cmp: Optional[bool] = ...,
            hash: Optional[bool] = ...,
            init: bool = ...,
            slots: bool = ...,
            frozen: bool = ...,
            weakref_slot: bool = ...,
            str: bool = ...,
            auto_attribs: bool = ...,
            kw_only: bool = ...,
            cache_hash: bool = ...,
            auto_exc: bool = ...,
            eq: Optional[bool] = ...,
            order: Optional[bool] = ...,
        ) -> Callable[[_C], _C]: ...
      |}
    );
    ( "click/__init__.pyi",
      {|
        # -*- coding: utf-8 -*-
        """
            click
            ~~~~~

            Click is a simple Python module that wraps the stdlib's optparse to make
            writing command line scripts fun.  Unlike other modules, it's based around
            a simple API that does not come with too much magic and is composable.

            In case optparse ever gets removed from the stdlib, it will be shipped by
            this module.

            :copyright: (c) 2014 by Armin Ronacher.
            :license: BSD, see LICENSE for more details.
        """

        # Core classes
        from .core import (
            Context as Context,
            BaseCommand as BaseCommand,
            Command as Command,
            MultiCommand as MultiCommand,
            Group as Group,
            CommandCollection as CommandCollection,
            Parameter as Parameter,
            Option as Option,
            Argument as Argument,
        )

        # Globals
        from .globals import get_current_context as get_current_context

        # Decorators
        from .decorators import (
            pass_context as pass_context,
            pass_obj as pass_obj,
            make_pass_decorator as make_pass_decorator,
            command as command,
            group as group,
            argument as argument,
            option as option,
            confirmation_option as confirmation_option,
            password_option as password_option,
            version_option as version_option,
            help_option as help_option,
        )

        # Types
        from .types import (
            ParamType as ParamType,
            File as File,
            FloatRange as FloatRange,
            DateTime as DateTime,
            Path as Path,
            Choice as Choice,
            IntRange as IntRange,
            Tuple as Tuple,
            STRING as STRING,
            INT as INT,
            FLOAT as FLOAT,
            BOOL as BOOL,
            UUID as UUID,
            UNPROCESSED as UNPROCESSED,
        )

        # Utilities
        from .utils import (
            echo as echo,
            get_binary_stream as get_binary_stream,
            get_text_stream as get_text_stream,
            open_file as open_file,
            format_filename as format_filename,
            get_app_dir as get_app_dir,
            get_os_args as get_os_args,
        )

        # Terminal functions
        from .termui import (
            prompt as prompt,
            confirm as confirm,
            get_terminal_size as get_terminal_size,
            echo_via_pager as echo_via_pager,
            progressbar as progressbar,
            clear as clear,
            style as style,
            unstyle as unstyle,
            secho as secho,
            edit as edit,
            launch as launch,
            getchar as getchar,
            pause as pause,
        )

        # Exceptions
        from .exceptions import (
            ClickException as ClickException,
            UsageError as UsageError,
            BadParameter as BadParameter,
            FileError as FileError,
            Abort as Abort,
            NoSuchOption as NoSuchOption,
            BadOptionUsage as BadOptionUsage,
            BadArgumentUsage as BadArgumentUsage,
            MissingParameter as MissingParameter,
        )

        # Formatting
        from .formatting import HelpFormatter as HelpFormatter, wrap_text as wrap_text

        # Parsing
        from .parser import OptionParser as OptionParser

        # Controls if click should emit the warning about the use of unicode
        # literals.
        disable_unicode_literals_warning: bool


        __version__: str
      |}
    );
    ( "click/core.pyi",
      {|
        from typing import (
            Any,
            Callable,
            ContextManager,
            Dict,
            Generator,
            Iterable,
            List,
            Mapping,
            NoReturn,
            Optional,
            Sequence,
            Set,
            Tuple,
            TypeVar,
            Union,
        )

        from click.formatting import HelpFormatter
        from click.parser import OptionParser

        _CC = TypeVar("_CC", bound=Callable[[], Any])

        def invoke_param_callback(
            callback: Callable[[Context, Parameter, Optional[str]], Any],
            ctx: Context,
            param: Parameter,
            value: Optional[str]
        ) -> Any:
            ...


        def augment_usage_errors(
            ctx: Context, param: Optional[Parameter] = ...
        ) -> ContextManager[None]:
            ...


        def iter_params_for_processing(
            invocation_order: Sequence[Parameter],
            declaration_order: Iterable[Parameter],
        ) -> Iterable[Parameter]:
            ...


        class Context:
            parent: Optional[Context]
            command: Command
            info_name: Optional[str]
            params: Dict[Any, Any]
            args: List[str]
            protected_args: List[str]
            obj: Any
            default_map: Mapping[str, Any]
            invoked_subcommand: Optional[str]
            terminal_width: Optional[int]
            max_content_width: Optional[int]
            allow_extra_args: bool
            allow_interspersed_args: bool
            ignore_unknown_options: bool
            help_option_names: List[str]
            token_normalize_func: Optional[Callable[[str], str]]
            resilient_parsing: bool
            auto_envvar_prefix: Optional[str]
            color: Optional[bool]
            _meta: Dict[str, Any]
            _close_callbacks: List[Any]
            _depth: int

            def __init__(
                self,
                command: Command,
                parent: Optional[Context] = ...,
                info_name: Optional[str] = ...,
                obj: Optional[Any] = ...,
                auto_envvar_prefix: Optional[str] = ...,
                default_map: Optional[Mapping[str, Any]] = ...,
                terminal_width: Optional[int] = ...,
                max_content_width: Optional[int] = ...,
                resilient_parsing: bool = ...,
                allow_extra_args: Optional[bool] = ...,
                allow_interspersed_args: Optional[bool] = ...,
                ignore_unknown_options: Optional[bool] = ...,
                help_option_names: Optional[List[str]] = ...,
                token_normalize_func: Optional[Callable[[str], str]] = ...,
                color: Optional[bool] = ...
            ) -> None:
                ...

            @property
            def meta(self) -> Dict[str, Any]:
                ...

            @property
            def command_path(self) -> str:
                ...

            def scope(self, cleanup: bool = ...) -> ContextManager[Context]:
                ...

            def make_formatter(self) -> HelpFormatter:
                ...

            def call_on_close(self, f: _CC) -> _CC: ...

            def close(self) -> None:
                ...

            def find_root(self) -> Context:
                ...

            def find_object(self, object_type: type) -> Any:
                ...

            def ensure_object(self, object_type: type) -> Any:
                ...

            def lookup_default(self, name: str) -> Any:
                ...

            def fail(self, message: str) -> NoReturn:
                ...

            def abort(self) -> NoReturn:
                ...

            def exit(self, code: Union[int, str] = ...) -> NoReturn:
                ...

            def get_usage(self) -> str:
                ...

            def get_help(self) -> str:
                ...

            def invoke(self, callback: Union[Command, Callable[..., Any]], *args, **kwargs) -> Any: ...
            def forward(self, callback: Union[Command, Callable[..., Any]], *args, **kwargs) -> Any: ...

        class BaseCommand:
            allow_extra_args: bool
            allow_interspersed_args: bool
            ignore_unknown_options: bool
            name: str
            context_settings: Dict[Any, Any]
            def __init__(self, name: str, context_settings: Optional[Dict[Any, Any]] = ...) -> None: ...

            def get_usage(self, ctx: Context) -> str:
                ...

            def get_help(self, ctx: Context) -> str:
                ...

            def make_context(
                self, info_name: str, args: List[str], parent: Optional[Context] = ..., **extra
            ) -> Context:
                ...

            def parse_args(self, ctx: Context, args: List[str]) -> List[str]:
                ...

            def invoke(self, ctx: Context) -> Any:
                ...

            def main(
                self,
                args: Optional[List[str]] = ...,
                prog_name: Optional[str] = ...,
                complete_var: Optional[str] = ...,
                standalone_mode: bool = ...,
                **extra
            ) -> Any:
                ...

            def __call__(self, *args, **kwargs) -> Any:
                ...


        class Command(BaseCommand):
            callback: Optional[Callable[..., Any]]
            params: List[Parameter]
            help: Optional[str]
            epilog: Optional[str]
            short_help: Optional[str]
            options_metavar: str
            add_help_option: bool
            hidden: bool
            deprecated: bool

            def __init__(
                self,
                name: str,
                context_settings: Optional[Dict[Any, Any]] = ...,
                callback: Optional[Callable[..., Any]] = ...,
                params: Optional[List[Parameter]] = ...,
                help: Optional[str] = ...,
                epilog: Optional[str] = ...,
                short_help: Optional[str] = ...,
                options_metavar: str = ...,
                add_help_option: bool = ...,
                hidden: bool = ...,
                deprecated: bool = ...,
            ) -> None:
                ...

            def get_params(self, ctx: Context) -> List[Parameter]:
                ...

            def format_usage(
                self,
                ctx: Context,
                formatter: HelpFormatter
            ) -> None:
                ...

            def collect_usage_pieces(self, ctx: Context) -> List[str]:
                ...

            def get_help_option_names(self, ctx: Context) -> Set[str]:
                ...

            def get_help_option(self, ctx: Context) -> Optional[Option]:
                ...

            def make_parser(self, ctx: Context) -> OptionParser:
                ...

            def get_short_help_str(self, limit: int = ...) -> str:
                ...

            def format_help(self, ctx: Context, formatter: HelpFormatter) -> None:
                ...

            def format_help_text(self, ctx: Context, formatter: HelpFormatter) -> None:
                ...

            def format_options(self, ctx: Context, formatter: HelpFormatter) -> None:
                ...

            def format_epilog(self, ctx: Context, formatter: HelpFormatter) -> None:
                ...


        _T = TypeVar('_T')
        _F = TypeVar('_F', bound=Callable[..., Any])


        class MultiCommand(Command):
            no_args_is_help: bool
            invoke_without_command: bool
            subcommand_metavar: str
            chain: bool
            result_callback: Callable[..., Any]

            def __init__(
                self,
                name: Optional[str] = ...,
                invoke_without_command: bool = ...,
                no_args_is_help: Optional[bool] = ...,
                subcommand_metavar: Optional[str] = ...,
                chain: bool = ...,
                result_callback: Optional[Callable[..., Any]] = ...,
                **attrs
            ) -> None:
                ...

            def resultcallback(
                self, replace: bool = ...
            ) -> Callable[[_F], _F]:
                ...

            def format_commands(self, ctx: Context, formatter: HelpFormatter) -> None:
                ...

            def resolve_command(
                self, ctx: Context, args: List[str]
            ) -> Tuple[str, Command, List[str]]:
                ...

            def get_command(self, ctx: Context, cmd_name: str) -> Optional[Command]:
                ...

            def list_commands(self, ctx: Context) -> Iterable[str]:
                ...


        class Group(MultiCommand):
            commands: Dict[str, Command]

            def __init__(
                self, name: Optional[str] = ..., commands: Optional[Dict[str, Command]] = ..., **attrs
            ) -> None:
                ...

            def add_command(self, cmd: Command, name: Optional[str] = ...):
                ...

            def command(self, *args, **kwargs) -> Callable[[Callable[..., Any]], Command]: ...
            def group(self, *args, **kwargs) -> Callable[[Callable[..., Any]], Group]: ...


        class CommandCollection(MultiCommand):
            sources: List[MultiCommand]

            def __init__(
                self, name: Optional[str] = ..., sources: Optional[List[MultiCommand]] = ..., **attrs
            ) -> None:
                ...

            def add_source(self, multi_cmd: MultiCommand) -> None:
                ...


        class _ParamType:
            name: str
            is_composite: bool
            envvar_list_splitter: Optional[str]

            def __call__(
                self,
                value: Optional[str],
                param: Optional[Parameter] = ...,
                ctx: Optional[Context] = ...,
            ) -> Any:
                ...

            def get_metavar(self, param: Parameter) -> str:
                ...

            def get_missing_message(self, param: Parameter) -> str:
                ...

            def convert(
                self,
                value: str,
                param: Optional[Parameter],
                ctx: Optional[Context],
            ) -> Any:
                ...

            def split_envvar_value(self, rv: str) -> List[str]:
                ...

            def fail(self, message: str, param: Optional[Parameter] = ..., ctx: Optional[Context] = ...) -> NoReturn:
                ...


        # This type is here to resolve https://github.com/python/mypy/issues/5275
        _ConvertibleType = Union[type, _ParamType, Tuple[Union[type, _ParamType], ...],
                                 Callable[[str], Any], Callable[[Optional[str]], Any]]


        class Parameter:
            param_type_name: str
            name: str
            opts: List[str]
            secondary_opts: List[str]
            type: _ParamType
            required: bool
            callback: Optional[Callable[[Context, Parameter, str], Any]]
            nargs: int
            multiple: bool
            expose_value: bool
            default: Any
            is_eager: bool
            metavar: Optional[str]
            envvar: Union[str, List[str], None]

            def __init__(
                self,
                param_decls: Optional[List[str]] = ...,
                type: Optional[_ConvertibleType] = ...,
                required: bool = ...,
                default: Optional[Any] = ...,
                callback: Optional[Callable[[Context, Parameter, str], Any]] = ...,
                nargs: Optional[int] = ...,
                metavar: Optional[str] = ...,
                expose_value: bool = ...,
                is_eager: bool = ...,
                envvar: Optional[Union[str, List[str]]] = ...
            ) -> None:
                ...

            @property
            def human_readable_name(self) -> str:
                ...

            def make_metavar(self) -> str:
                ...

            def get_default(self, ctx: Context) -> Any:
                ...

            def add_to_parser(self, parser: OptionParser, ctx: Context) -> None:
                ...

            def consume_value(self, ctx: Context, opts: Dict[str, Any]) -> Any:
                ...

            def type_cast_value(self, ctx: Context, value: Any) -> Any:
                ...

            def process_value(self, ctx: Context, value: Any) -> Any:
                ...

            def value_is_missing(self, value: Any) -> bool:
                ...

            def full_process_value(self, ctx: Context, value: Any) -> Any:
                ...

            def resolve_envvar_value(self, ctx: Context) -> str:
                ...

            def value_from_envvar(self, ctx: Context) -> Union[str, List[str]]:
                ...

            def handle_parse_result(
                self, ctx: Context, opts: Dict[str, Any], args: List[str]
            ) -> Tuple[Any, List[str]]:
                ...

            def get_help_record(self, ctx: Context) -> Tuple[str, str]:
                ...

            def get_usage_pieces(self, ctx: Context) -> List[str]:
                ...

            def get_error_hint(self, ctx: Context) -> str:
                ...


        class Option(Parameter):
            prompt: str  # sic
            confirmation_prompt: bool
            hide_input: bool
            is_flag: bool
            flag_value: Any
            is_bool_flag: bool
            count: bool
            multiple: bool
            allow_from_autoenv: bool
            help: Optional[str]
            hidden: bool
            show_default: bool
            show_choices: bool
            show_envvar: bool

            def __init__(
                self,
                param_decls: Optional[List[str]] = ...,
                show_default: bool = ...,
                prompt: Union[bool, str] = ...,
                confirmation_prompt: bool = ...,
                hide_input: bool = ...,
                is_flag: Optional[bool] = ...,
                flag_value: Optional[Any] = ...,
                multiple: bool = ...,
                count: bool = ...,
                allow_from_autoenv: bool = ...,
                type: Optional[_ConvertibleType] = ...,
                help: Optional[str] = ...,
                hidden: bool = ...,
                show_choices: bool = ...,
                show_envvar: bool = ...,
                **attrs
            ) -> None:
                ...

            def prompt_for_value(self, ctx: Context) -> Any:
                ...


        class Argument(Parameter):
            def __init__(
                self,
                param_decls: Optional[List[str]] = ...,
                required: Optional[bool] = ...,
                **attrs
            ) -> None:
                ...
      |}
    );
    ( "click/decorators.pyi",
      {|
        from distutils.version import Version
        from typing import Any, Callable, Dict, List, Optional, Tuple, Type, TypeVar, Union, Text, overload

        from click.core import Command, Group, Argument, Option, Parameter, Context, _ConvertibleType

        _T = TypeVar('_T')
        _F = TypeVar('_F', bound=Callable[..., Any])

        # Until https://github.com/python/mypy/issues/3924 is fixed you can't do the following:
        # _Decorator = Callable[[_F], _F]

        _Callback = Callable[
            [Context, Union[Option, Parameter], Any],
            Any
        ]

        def pass_context(_T) -> _T:
            ...


        def pass_obj(_T) -> _T:
            ...


        def make_pass_decorator(
            object_type: type, ensure: bool = ...
        ) -> Callable[[_T], _T]:
            ...


        # NOTE: Decorators below have **attrs converted to concrete constructor
        # arguments from core.pyi to help with type checking.

        def command(
            name: Optional[str] = ...,
            cls: Optional[Type[Command]] = ...,
            # Command
            context_settings: Optional[Dict[Any, Any]] = ...,
            help: Optional[str] = ...,
            epilog: Optional[str] = ...,
            short_help: Optional[str] = ...,
            options_metavar: str = ...,
            add_help_option: bool = ...,
            hidden: bool = ...,
            deprecated: bool = ...,
        ) -> Callable[[Callable[..., Any]], Command]: ...

        # This inherits attrs from Group, MultiCommand and Command.

        def group(
            name: Optional[str] = ...,
            cls: Type[Command] = ...,
            # Group
            commands: Optional[Dict[str, Command]] = ...,
            # MultiCommand
            invoke_without_command: bool = ...,
            no_args_is_help: Optional[bool] = ...,
            subcommand_metavar: Optional[str] = ...,
            chain: bool = ...,
            result_callback: Optional[Callable[..., Any]] = ...,
            # Command
            help: Optional[str] = ...,
            epilog: Optional[str] = ...,
            short_help: Optional[str] = ...,
            options_metavar: str = ...,
            add_help_option: bool = ...,
            hidden: bool = ...,
            deprecated: bool = ...,
            # User-defined
            **kwargs: Any,
        ) -> Callable[[Callable[..., Any]], Group]: ...

        def argument(
            *param_decls: str,
            cls: Type[Argument] = ...,
            # Argument
            required: Optional[bool] = ...,
            # Parameter
            type: Optional[_ConvertibleType] = ...,
            default: Optional[Any] = ...,
            callback: Optional[_Callback] = ...,
            nargs: Optional[int] = ...,
            metavar: Optional[str] = ...,
            expose_value: bool = ...,
            is_eager: bool = ...,
            envvar: Optional[Union[str, List[str]]] = ...,
            autocompletion: Optional[Callable[[Any, List[str], str], List[Union[str, Tuple[str, str]]]]] = ...,
        ) -> Callable[[_F], _F]:
            ...


        @overload
        def option(
            *param_decls: str,
            cls: Type[Option] = ...,
            # Option
            show_default: bool = ...,
            prompt: Union[bool, Text] = ...,
            confirmation_prompt: bool = ...,
            hide_input: bool = ...,
            is_flag: Optional[bool] = ...,
            flag_value: Optional[Any] = ...,
            multiple: bool = ...,
            count: bool = ...,
            allow_from_autoenv: bool = ...,
            type: Optional[_ConvertibleType] = ...,
            help: Optional[str] = ...,
            show_choices: bool = ...,
            # Parameter
            default: Optional[Any] = ...,
            required: bool = ...,
            callback: Optional[_Callback] = ...,
            nargs: Optional[int] = ...,
            metavar: Optional[str] = ...,
            expose_value: bool = ...,
            is_eager: bool = ...,
            envvar: Optional[Union[str, List[str]]] = ...,
            # User-defined
            **kwargs: Any,
        ) -> Callable[[_F], _F]:
            ...


        @overload
        def option(
            *param_decls: str,
            cls: Type[Option] = ...,
            # Option
            show_default: bool = ...,
            prompt: Union[bool, Text] = ...,
            confirmation_prompt: bool = ...,
            hide_input: bool = ...,
            is_flag: Optional[bool] = ...,
            flag_value: Optional[Any] = ...,
            multiple: bool = ...,
            count: bool = ...,
            allow_from_autoenv: bool = ...,
            type: _T = ...,
            help: Optional[str] = ...,
            show_choices: bool = ...,
            # Parameter
            default: Optional[Any] = ...,
            required: bool = ...,
            callback: Optional[Callable[[Context, Union[Option, Parameter], Union[bool, int, str]], _T]] = ...,
            nargs: Optional[int] = ...,
            metavar: Optional[str] = ...,
            expose_value: bool = ...,
            is_eager: bool = ...,
            envvar: Optional[Union[str, List[str]]] = ...,
            # User-defined
            **kwargs: Any,
        ) -> Callable[[_F], _F]:
            ...


        @overload
        def option(
            *param_decls: str,
            cls: Type[Option] = ...,
            # Option
            show_default: bool = ...,
            prompt: Union[bool, Text] = ...,
            confirmation_prompt: bool = ...,
            hide_input: bool = ...,
            is_flag: Optional[bool] = ...,
            flag_value: Optional[Any] = ...,
            multiple: bool = ...,
            count: bool = ...,
            allow_from_autoenv: bool = ...,
            type: Type[str] = ...,
            help: Optional[str] = ...,
            show_choices: bool = ...,
            # Parameter
            default: Optional[Any] = ...,
            required: bool = ...,
            callback: Callable[[Context, Union[Option, Parameter], str], Any] = ...,
            nargs: Optional[int] = ...,
            metavar: Optional[str] = ...,
            expose_value: bool = ...,
            is_eager: bool = ...,
            envvar: Optional[Union[str, List[str]]] = ...,
            # User-defined
            **kwargs: Any,
        ) -> Callable[[_F], _F]:
            ...


        @overload
        def option(
            *param_decls: str,
            cls: Type[Option] = ...,
            # Option
            show_default: bool = ...,
            prompt: Union[bool, Text] = ...,
            confirmation_prompt: bool = ...,
            hide_input: bool = ...,
            is_flag: Optional[bool] = ...,
            flag_value: Optional[Any] = ...,
            multiple: bool = ...,
            count: bool = ...,
            allow_from_autoenv: bool = ...,
            type: Type[int] = ...,
            help: Optional[str] = ...,
            show_choices: bool = ...,
            # Parameter
            default: Optional[Any] = ...,
            required: bool = ...,
            callback: Callable[[Context, Union[Option, Parameter], int], Any] = ...,
            nargs: Optional[int] = ...,
            metavar: Optional[str] = ...,
            expose_value: bool = ...,
            is_eager: bool = ...,
            envvar: Optional[Union[str, List[str]]] = ...,
            # User-defined
            **kwargs: Any,
        ) -> Callable[[_F], _F]:
            ...


        def confirmation_option(
            *param_decls: str,
            cls: Type[Option] = ...,
            # Option
            show_default: bool = ...,
            prompt: Union[bool, Text] = ...,
            confirmation_prompt: bool = ...,
            hide_input: bool = ...,
            is_flag: bool = ...,
            flag_value: Optional[Any] = ...,
            multiple: bool = ...,
            count: bool = ...,
            allow_from_autoenv: bool = ...,
            type: Optional[_ConvertibleType] = ...,
            help: str = ...,
            show_choices: bool = ...,
            # Parameter
            default: Optional[Any] = ...,
            callback: Optional[_Callback] = ...,
            nargs: Optional[int] = ...,
            metavar: Optional[str] = ...,
            expose_value: bool = ...,
            is_eager: bool = ...,
            envvar: Optional[Union[str, List[str]]] = ...
        ) -> Callable[[_F], _F]:
            ...


        def password_option(
            *param_decls: str,
            cls: Type[Option] = ...,
            # Option
            show_default: bool = ...,
            prompt: Union[bool, Text] = ...,
            confirmation_prompt: bool = ...,
            hide_input: bool = ...,
            is_flag: Optional[bool] = ...,
            flag_value: Optional[Any] = ...,
            multiple: bool = ...,
            count: bool = ...,
            allow_from_autoenv: bool = ...,
            type: Optional[_ConvertibleType] = ...,
            help: Optional[str] = ...,
            show_choices: bool = ...,
            # Parameter
            default: Optional[Any] = ...,
            callback: Optional[_Callback] = ...,
            nargs: Optional[int] = ...,
            metavar: Optional[str] = ...,
            expose_value: bool = ...,
            is_eager: bool = ...,
            envvar: Optional[Union[str, List[str]]] = ...
        ) -> Callable[[_F], _F]:
            ...


        def version_option(
            version: Optional[Union[str, Version]] = ...,
            *param_decls: str,
            cls: Type[Option] = ...,
            # Option
            prog_name: Optional[str] = ...,
            message: Optional[str] = ...,
            show_default: bool = ...,
            prompt: Union[bool, Text] = ...,
            confirmation_prompt: bool = ...,
            hide_input: bool = ...,
            is_flag: bool = ...,
            flag_value: Optional[Any] = ...,
            multiple: bool = ...,
            count: bool = ...,
            allow_from_autoenv: bool = ...,
            type: Optional[_ConvertibleType] = ...,
            help: str = ...,
            show_choices: bool = ...,
            # Parameter
            default: Optional[Any] = ...,
            callback: Optional[_Callback] = ...,
            nargs: Optional[int] = ...,
            metavar: Optional[str] = ...,
            expose_value: bool = ...,
            is_eager: bool = ...,
            envvar: Optional[Union[str, List[str]]] = ...
        ) -> Callable[[_F], _F]:
            ...


        def help_option(
            *param_decls: str,
            cls: Type[Option] = ...,
            # Option
            show_default: bool = ...,
            prompt: Union[bool, Text] = ...,
            confirmation_prompt: bool = ...,
            hide_input: bool = ...,
            is_flag: bool = ...,
            flag_value: Optional[Any] = ...,
            multiple: bool = ...,
            count: bool = ...,
            allow_from_autoenv: bool = ...,
            type: Optional[_ConvertibleType] = ...,
            help: str = ...,
            show_choices: bool = ...,
            # Parameter
            default: Optional[Any] = ...,
            callback: Optional[_Callback] = ...,
            nargs: Optional[int] = ...,
            metavar: Optional[str] = ...,
            expose_value: bool = ...,
            is_eager: bool = ...,
            envvar: Optional[Union[str, List[str]]] = ...
        ) -> Callable[[_F], _F]:
            ...
      |}
    );
    "placeholder_stub.pyi", {|
        # pyre-placeholder-stub
        |};
  ]
  @ sqlalchemy_stubs
  @ sqlalchemy_1_4_stubs


let mock_signature =
  {
    Define.Signature.name = Node.create_with_default_location (Reference.create "$empty");
    parameters = [];
    decorators = [];
    return_annotation = None;
    async = false;
    generator = false;
    parent = None;
    nesting_define = None;
  }


let mock_define =
  { Define.signature = mock_signature; captures = []; unbound_names = []; body = [] }


let create_type_alias_table type_aliases =
  let aliases ?replace_unbound_parameters_with_any:_ primitive =
    type_aliases primitive >>| fun alias -> Type.TypeAlias alias
  in
  aliases


let mock_scheduler () =
  Taint.ModelParser.ClassDefinitionsCache.invalidate ();
  Scheduler.create_sequential ()


let update_environments
    ?(scheduler = mock_scheduler ())
    ~configuration
    ~ast_environment
    ast_environment_trigger
  =
  let environment = AnnotatedGlobalEnvironment.create ast_environment in
  ( environment,
    AnnotatedGlobalEnvironment.update_this_and_all_preceding_environments
      environment
      ~scheduler
      ~configuration
      ast_environment_trigger )


module ScratchProject = struct
  type t = {
    context: test_ctxt;
    configuration: Configuration.Analysis.t;
    module_tracker: ModuleTracker.t;
  }

  module BuiltTypeEnvironment = struct
    type t = {
      sources: Source.t list;
      type_environment: TypeEnvironment.t;
    }
  end

  module BuiltGlobalEnvironment = struct
    type t = {
      sources: Source.t list;
      global_environment: AnnotatedGlobalEnvironment.t;
    }
  end

  let clean_ast_shared_memory ~configuration module_tracker ast_environment =
    let deletions =
      ModuleTracker.source_paths module_tracker
      |> List.map ~f:(fun { SourcePath.qualifier; _ } -> qualifier)
      |> List.map ~f:(fun qualifier -> ModuleTracker.IncrementalUpdate.Delete qualifier)
    in
    AstEnvironment.update
      ~configuration
      ~scheduler:(mock_scheduler ())
      ast_environment
      (Update deletions)
    |> ignore


  let setup
      ?(incremental_style = Configuration.Analysis.FineGrained)
      ~context
      ?(external_sources = [])
      ?(show_error_traces = false)
      ?(include_typeshed_stubs = true)
      ?(include_helper_builtins = true)
      ?(infer = false)
      sources
    =
    let add_source ~root (relative, content) =
      let content = trim_extra_indentation content in
      let file = File.create ~content (Path.create_relative ~root ~relative) in
      File.write file
    in
    (* We assume that there's only one checked source directory that acts as the local root as well. *)
    let local_root = bracket_tmpdir context |> Path.create_absolute in
    (* We assume that there's only one external source directory that acts as the local root as
       well. *)
    let external_root = bracket_tmpdir context |> Path.create_absolute in
    let log_directory = bracket_tmpdir context in
    let configuration =
      Configuration.Analysis.create
        ~local_root
        ~source_path:[SearchPath.Root local_root]
        ~search_path:[SearchPath.Root external_root]
        ~log_directory
        ~filter_directories:[local_root]
        ~ignore_all_errors:[external_root]
        ~incremental_style
        ~features:{ Configuration.Features.default with go_to_definition = true }
        ~show_error_traces
        ~parallel:false
        ~infer
        ()
    in
    let external_sources =
      if include_typeshed_stubs then
        typeshed_stubs ~include_helper_builtins () @ external_sources
      else
        external_sources
    in
    List.iter sources ~f:(add_source ~root:local_root);
    List.iter external_sources ~f:(add_source ~root:external_root);
    let module_tracker = ModuleTracker.create configuration in
    { context; configuration; module_tracker }


  (* Incremental checks already call ModuleTracker.update, so we don't need to update the state
     here. *)
  let add_source
      { configuration = { Configuration.Analysis.source_path; search_path; _ }; _ }
      ~is_external
      (relative, content)
    =
    let path =
      let root =
        if is_external then
          match search_path with
          | SearchPath.Root root :: _ -> root
          | _ ->
              failwith
                "Scratch projects should have the external root at the start of their search path."
        else
          match source_path with
          | SearchPath.Root root :: _ -> root
          | _ -> failwith "Scratch projects should have only one source path."
      in
      Path.create_relative ~root ~relative
    in
    let file = File.create ~content path in
    File.write file


  let configuration_of { configuration; _ } = configuration

  let source_paths_of { module_tracker; _ } = ModuleTracker.source_paths module_tracker

  let qualifiers_of { module_tracker; _ } =
    ModuleTracker.source_paths module_tracker
    |> List.map ~f:(fun { SourcePath.qualifier; _ } -> qualifier)


  let build_ast_environment { context; configuration; module_tracker } =
    let ast_environment = AstEnvironment.create module_tracker in
    let () =
      (* Clean shared memory up before the test *)
      clean_ast_shared_memory ~configuration module_tracker ast_environment;
      let set_up_shared_memory _ = () in
      let tear_down_shared_memory () _ =
        clean_ast_shared_memory ~configuration module_tracker ast_environment
      in
      (* Clean shared memory up after the test *)
      OUnit2.bracket set_up_shared_memory tear_down_shared_memory context
    in
    ast_environment


  let parse_sources ({ configuration; module_tracker; _ } as project) =
    let ast_environment = build_ast_environment project in
    let ast_environment_update_result =
      Analysis.ModuleTracker.source_paths module_tracker
      |> List.map ~f:(fun source_path -> ModuleTracker.IncrementalUpdate.NewExplicit source_path)
      |> (fun updates -> AstEnvironment.Update updates)
      |> Analysis.AstEnvironment.update
           ~configuration
           ~scheduler:(mock_scheduler ())
           ast_environment
    in
    ast_environment, ast_environment_update_result


  let build_global_environment ({ configuration; _ } as project) =
    let ast_environment = build_ast_environment project in
    let global_environment, update_result =
      update_environments ~ast_environment ~configuration ColdStart
    in
    let sources =
      AnnotatedGlobalEnvironment.UpdateResult.ast_environment_update_result update_result
      |> AstEnvironment.UpdateResult.invalidated_modules
      |> List.filter_map
           ~f:
             (AstEnvironment.ReadOnly.get_processed_source
                (AstEnvironment.read_only ast_environment))
    in
    { BuiltGlobalEnvironment.sources; global_environment }


  let build_type_environment ?call_graph_builder project =
    let { BuiltGlobalEnvironment.sources; global_environment } = build_global_environment project in
    let type_environment = TypeEnvironment.create global_environment in
    let configuration = configuration_of project in
    List.map sources ~f:(fun { Source.source_path = { SourcePath.qualifier; _ }; _ } -> qualifier)
    |> TypeCheck.legacy_run_on_modules
         ~scheduler:(Scheduler.create_sequential ())
         ~configuration
         ~environment:type_environment
         ?call_graph_builder;
    { BuiltTypeEnvironment.sources; type_environment }


  let build_type_environment_and_postprocess ?call_graph_builder project =
    let built_type_environment = build_type_environment ?call_graph_builder project in
    let errors =
      List.map
        built_type_environment.sources
        ~f:(fun { Source.source_path = { SourcePath.qualifier; _ }; _ } -> qualifier)
      |> Postprocessing.run
           ~scheduler:(Scheduler.create_sequential ())
           ~configuration:(configuration_of project)
           ~environment:(TypeEnvironment.read_only built_type_environment.type_environment)
    in
    built_type_environment, errors


  let build_global_resolution project =
    let { BuiltGlobalEnvironment.global_environment; _ } = build_global_environment project in
    AnnotatedGlobalEnvironment.read_only global_environment |> GlobalResolution.create


  let build_resolution project =
    let global_resolution = build_global_resolution project in
    TypeCheck.resolution
      global_resolution (* TODO(T65923817): Eliminate the need of creating a dummy context here *)
      (module TypeCheck.DummyContext)
end

type test_update_environment_with_t = {
  handle: string;
  source: string;
}
[@@deriving compare, eq, show]

let assert_errors
    ?(debug = true)
    ?(strict = false)
    ?(infer = false)
    ?(show_error_traces = false)
    ?(concise = false)
    ?(handle = "test.py")
    ?(update_environment_with = [])
    ?(include_line_numbers = false)
    ~context
    ~check
    source
    errors
  =
  (if SourcePath.qualifier_of_relative handle |> Reference.is_empty then
     let message =
       Format.sprintf
         "Cannot use %s as test file name: Empty qualifier in test is no longer acceptable."
         handle
     in
     failwith message);

  let descriptions =
    let errors =
      let configuration, sources, ast_environment, environment =
        let project =
          let external_sources =
            List.map update_environment_with ~f:(fun { handle; source } -> handle, source)
          in
          ScratchProject.setup ~context ~external_sources [handle, source]
        in
        let { ScratchProject.BuiltGlobalEnvironment.sources; global_environment } =
          ScratchProject.build_global_environment project
        in
        let configuration = ScratchProject.configuration_of project in
        ( configuration,
          sources,
          AnnotatedGlobalEnvironment.ast_environment global_environment |> AstEnvironment.read_only,
          TypeEnvironment.create global_environment )
      in
      let configuration = { configuration with debug; strict; infer } in
      let source =
        List.find_exn sources ~f:(fun { Source.source_path = { SourcePath.relative; _ }; _ } ->
            String.equal handle relative)
      in
      check ~configuration ~environment ~source
      |> List.map
           ~f:
             (AnalysisError.instantiate
                ~show_error_traces
                ~lookup:
                  (AstEnvironment.ReadOnly.get_real_path_relative ~configuration ast_environment))
    in
    let errors_with_any_location =
      List.filter_map errors ~f:(fun error ->
          let location = AnalysisError.Instantiated.location error in
          Option.some_if (Location.WithPath.equal location Location.WithPath.any) location)
    in
    let show_description ~concise error =
      if concise then
        AnalysisError.Instantiated.concise_description error
      else
        AnalysisError.Instantiated.description error
    in
    let found_any = not (List.is_empty errors_with_any_location) in
    (if found_any then
       let errors = List.map ~f:(show_description ~concise) errors |> String.concat ~sep:"\n" in
       Format.sprintf "\nLocation.any cannot be attached to errors: %s\n" errors |> ignore);
    assert_false found_any;
    let to_string error =
      let description = show_description ~concise error in
      if include_line_numbers then
        let line = AnalysisError.Instantiated.location error |> Location.WithPath.line in
        Format.sprintf "%d: %s" line description
      else
        description
    in
    List.map ~f:to_string errors
  in
  Memory.reset_shared_memory ();
  assert_equal ~cmp:(List.equal String.equal) ~printer:(String.concat ~sep:"\n") errors descriptions


let assert_equivalent_attributes ~context source expected =
  let handle = "test.py" in
  let attributes class_type source =
    Memory.reset_shared_memory ();
    let { ScratchProject.BuiltGlobalEnvironment.global_environment; _ } =
      ScratchProject.setup ~context [handle, source] |> ScratchProject.build_global_environment
    in
    let global_resolution =
      AnnotatedGlobalEnvironment.read_only global_environment |> GlobalResolution.create
    in
    let compare_by_name left right =
      String.compare (Annotated.Attribute.name left) (Annotated.Attribute.name right)
    in
    Type.split class_type
    |> fst
    |> Type.primitive_name
    >>= GlobalResolution.attributes ~transitive:false ~resolution:global_resolution
    |> (fun attributes -> Option.value_exn attributes)
    |> List.sort ~compare:compare_by_name
    |> List.map
         ~f:
           (GlobalResolution.instantiate_attribute
              ~resolution:global_resolution
              ~accessed_through_class:false)
  in
  let class_names =
    let expected =
      List.map expected ~f:(fun definition -> parse ~handle definition |> Preprocessing.preprocess)
    in
    let get_name_if_class { Node.value; _ } =
      match value with
      | Statement.Class { Class.name = { Node.value; _ }; _ } -> Some (Reference.show value)
      | _ -> None
    in
    List.map ~f:Source.statements expected
    |> List.filter_map ~f:List.hd
    |> List.filter_map ~f:get_name_if_class
    |> List.map ~f:(fun name -> Type.Primitive name)
  in
  let assert_class_equal class_type expected =
    let pp_as_sexps format l =
      List.map l ~f:Annotated.Attribute.sexp_of_instantiated
      |> List.map ~f:Sexp.to_string_hum
      |> String.concat ~sep:"\n"
      |> Format.fprintf format "%s\n"
    in
    let simple_print l =
      let simple attribute =
        let annotation = Annotated.Attribute.annotation attribute |> Annotation.annotation in
        let name = Annotated.Attribute.name attribute in
        Printf.sprintf "%s, %s" name (Type.show annotation)
      in
      List.map l ~f:simple |> String.concat ~sep:"\n"
    in
    assert_equal
      ~printer:simple_print
      ~pp_diff:(diff ~print:pp_as_sexps)
      (attributes class_type expected)
      (attributes class_type source)
  in
  List.iter2_exn ~f:assert_class_equal class_names expected


module MockClassHierarchyHandler = struct
  type t = {
    edges: ClassHierarchy.Target.t list IndexTracker.Table.t;
    all_indices: IndexTracker.Hash_set.t;
  }

  let create () =
    { edges = IndexTracker.Table.create (); all_indices = IndexTracker.Hash_set.create () }


  let copy { edges; all_indices } =
    { edges = Hashtbl.copy edges; all_indices = Hash_set.copy all_indices }


  let pp format { edges; _ } =
    let print_edge (source, targets) =
      let targets =
        let target { ClassHierarchy.Target.target; parameters } =
          Format.asprintf
            "%s [%a]"
            (IndexTracker.annotation target)
            (Type.pp_parameters ~pp_type:Type.pp_concise)
            parameters
        in
        targets |> List.map ~f:target |> String.concat ~sep:", "
      in
      Format.fprintf format "  %s -> %s\n" (IndexTracker.annotation source) targets
    in
    Format.fprintf format "Edges:\n";
    List.iter ~f:print_edge (Hashtbl.to_alist edges)


  let show order = Format.asprintf "%a" pp order

  let set table ~key ~data = Hashtbl.set table ~key ~data

  let handler order =
    (module struct
      let edges = Hashtbl.find order.edges

      let extends_placeholder_stub _ = false

      let contains annotation = Hash_set.mem order.all_indices (IndexTracker.index annotation)
    end : ClassHierarchy.Handler)


  let connect ?(parameters = []) order ~predecessor ~successor =
    let predecessor = IndexTracker.index predecessor in
    let successor = IndexTracker.index successor in
    let edges = order.edges in
    (* Add edges. *)
    let successors = Hashtbl.find edges predecessor |> Option.value ~default:[] in
    Hashtbl.set
      edges
      ~key:predecessor
      ~data:({ ClassHierarchy.Target.target = successor; parameters } :: successors)


  let insert order annotation =
    let index = IndexTracker.index annotation in
    Hash_set.add order.all_indices index;
    Hashtbl.set order.edges ~key:index ~data:[]
end
