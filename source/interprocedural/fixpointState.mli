(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* Encapsulates the shared state maintained and computed during the outer fixpoint computation.

   Separates errors from function call models in order to reduce deserialization cost when models
   are looked up. Also caches the fixpoint state of a call model separately so it can be looked up
   cheaply. *)

open Core
module SharedMemory = Memory

module Epoch : sig
  type t = int [@@deriving show]

  val predefined : t

  val initial : t
end

type step = {
  epoch: Epoch.t;
  iteration: int;
}
[@@deriving show]

type t = {
  is_partial: bool;
  (* Whether to reanalyze this and its callers. *)
  model: AnalysisResult.model_t;
  (* Model to use at call sites. *)
  result: AnalysisResult.result_t; (* The result of the analysis. *)
}

type meta_data = {
  is_partial: bool;
  step: step;
}

module KeySet : Caml.Set.S with type elt = Callable.t

module KeyMap : MyMap.S with type key = Callable.t

val get_new_model : [< Callable.t ] -> AnalysisResult.model_t option

val get_old_model : [< Callable.t ] -> AnalysisResult.model_t option

val get_model : [< Callable.t ] -> AnalysisResult.model_t option

val get_result : [< Callable.t ] -> AnalysisResult.result_t

val get_is_partial : [< Callable.t ] -> bool

val get_meta_data : [< Callable.t ] -> meta_data option

val has_model : [< Callable.t ] -> bool

val meta_data_to_string : meta_data -> string

val add : step -> [< Callable.t ] -> t -> unit

val add_predefined : Epoch.t -> [< Callable.t ] -> AnalysisResult.model_t -> unit

val get_new_models : KeySet.t -> AnalysisResult.model_t option KeyMap.t

val get_new_results : KeySet.t -> AnalysisResult.result_t option KeyMap.t

val oldify : KeySet.t -> unit

val remove_new : KeySet.t -> unit

val remove_old : KeySet.t -> unit

val is_initial_iteration : step -> bool
