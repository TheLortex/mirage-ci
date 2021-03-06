type t
(** An obuilder spec *)

val make : string -> t
(** [make image] Initialize the spec to build on [image] *)

val add : Obuilder_spec.op list -> t -> t
(** Add instructions to the spec *)

val finish : t -> Obuilder_spec.t
(** Finalize the spec and obtain the obuilder content. *)
