%% Copyright (c) 2011, Loïc Hoguin <essen@dev-extend.eu>
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

-module(cowboy_tcp_transport).
-export([name/0, messages/0, listen/1, accept/2, recv/3, send/2, setopts/2,
	controlling_process/2, peername/1, close/1]). %% API.

%% API.

-spec name() -> tcp.
name() -> tcp.

-spec messages() -> {tcp, tcp_closed, tcp_error}.
messages() -> {tcp, tcp_closed, tcp_error}.

-spec listen([{port, inet:ip_port()} | {ip, inet:ip_address()}])
	-> {ok, inet:socket()} | {error, atom()}.
listen(Opts) ->
	{port, Port} = lists:keyfind(port, 1, Opts),
	Backlog = proplists:get_value(backlog, Opts, 1024),
	ListenOpts0 = [binary, {active, false},
		{backlog, Backlog}, {packet, raw}, {reuseaddr, true}],
	ListenOpts =
		case lists:keyfind(ip, 1, Opts) of
			false -> ListenOpts0;
			Ip -> [Ip|ListenOpts0]
		end,
	gen_tcp:listen(Port, ListenOpts).

-spec accept(inet:socket(), timeout())
	-> {ok, inet:socket()} | {error, closed | timeout | atom()}.
accept(LSocket, Timeout) ->
	gen_tcp:accept(LSocket, Timeout).

-spec recv(inet:socket(), non_neg_integer(), timeout())
	-> {ok, any()} | {error, closed | atom()}.
recv(Socket, Length, Timeout) ->
	gen_tcp:recv(Socket, Length, Timeout).

-spec send(inet:socket(), iolist()) -> ok | {error, atom()}.
send(Socket, Packet) ->
	gen_tcp:send(Socket, Packet).

-spec setopts(inet:socket(), list()) -> ok | {error, atom()}.
setopts(Socket, Opts) ->
	inet:setopts(Socket, Opts).

-spec controlling_process(inet:socket(), pid())
	-> ok | {error, closed | not_owner | atom()}.
controlling_process(Socket, Pid) ->
	gen_tcp:controlling_process(Socket, Pid).

-spec peername(inet:socket())
	-> {ok, {inet:ip_address(), inet:ip_port()}} | {error, atom()}.
peername(Socket) ->
	inet:peername(Socket).

-spec close(inet:socket()) -> ok.
close(Socket) ->
	gen_tcp:close(Socket).
