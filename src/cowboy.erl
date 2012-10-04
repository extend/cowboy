%% Copyright (c) 2011-2012, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

%% @doc Convenience API to start and stop HTTP/HTTPS listeners.
-module(cowboy).

-export([start_http/4]).
-export([start_https/4]).
-export([stop_listener/1]).
-export([http_child_spec/4]).
-export([https_child_spec/4]).

%% @doc Start an HTTP listener.
-spec start_http(any(), non_neg_integer(), any(), any()) -> {ok, pid()}.
start_http(Ref, NbAcceptors, TransOpts, ProtoOpts)
		when is_integer(NbAcceptors), NbAcceptors > 0 ->
	ranch:start_listener(Ref, NbAcceptors,
		ranch_tcp, TransOpts, cowboy_protocol, ProtoOpts).

%% @doc Start an HTTPS listener.
-spec start_https(any(), non_neg_integer(), any(), any()) -> {ok, pid()}.
start_https(Ref, NbAcceptors, TransOpts, ProtoOpts)
		when is_integer(NbAcceptors), NbAcceptors > 0 ->
	ranch:start_listener(Ref, NbAcceptors,
		ranch_ssl, TransOpts, cowboy_protocol, ProtoOpts).

%% @doc Stop a listener.
-spec stop_listener(any()) -> ok.
stop_listener(Ref) ->
	ranch:stop_listener(Ref).

%% @doc Return an http child spec suitable for embedding.
%%
%% When you want to embed cowboy in another application, you can use this
%% function to create an http <em>ChildSpec</em> suitable for use in a
%% supervisor. The parameters are the same as in <em>start_listener/6</em> but
%% rather than hooking the listener to the Ranch internal supervisor, it just
%% returns the spec.
-spec http_child_spec(any(), non_neg_integer(), any(), any())
	-> supervisor:child_spec().
http_child_spec(Ref, NbAcceptors, TransOpts, ProtoOpts)
		when is_integer(NbAcceptors), NbAcceptors > 0 ->
    ranch:child_spec(Ref, NbAcceptors,
        ranch_tcp, TransOpts, cowboy_protocol, ProtoOpts).

%% @doc Return an https child spec suitable for embedding.
%%
%% When you want to embed cowboy in another application, you can use this
%% function to create an http <em>ChildSpec</em> suitable for use in a
%% supervisor. The parameters are the same as in <em>start_listener/6</em> but
%% rather than hooking the listener to the Ranch internal supervisor, it just
%% returns the spec.
-spec https_child_spec(any(), non_neg_integer(), any(), any())
	-> supervisor:child_spec().
https_child_spec(Ref, NbAcceptors, TransOpts, ProtoOpts)
		when is_integer(NbAcceptors), NbAcceptors > 0 ->
    ranch:child_spec(Ref, NbAcceptors,
        ranch_ssl, TransOpts, cowboy_protocol, ProtoOpts).
