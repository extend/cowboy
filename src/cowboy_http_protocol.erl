%% Copyright (c) 2011, Loïc Hoguin <essen@dev-extend.eu>
%% Copyright (c) 2011, Anthony Ramine <nox@dev-extend.eu>
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

-module(cowboy_http_protocol).
-export([start_link/3]). %% API.
-export([init/3, parse_request/1]). %% FSM.

-include("include/http.hrl").

-record(state, {
	socket :: inet:socket(),
	transport :: module(),
	dispatch :: cowboy_dispatcher:dispatch_rules(),
	handler :: {Handler::module(), Opts::term()},
	req_empty_lines = 0 :: integer(),
	max_empty_lines :: integer(),
	timeout :: timeout(),
	connection = keepalive :: keepalive | close,
	buffer = <<>> :: binary()
}).

%% API.

-spec start_link(Socket::inet:socket(), Transport::module(), Opts::term())
	-> {ok, Pid::pid()}.
start_link(Socket, Transport, Opts) ->
	Pid = spawn_link(?MODULE, init, [Socket, Transport, Opts]),
	{ok, Pid}.

%% FSM.

-spec init(Socket::inet:socket(), Transport::module(), Opts::term()) -> ok.
init(Socket, Transport, Opts) ->
	Dispatch = proplists:get_value(dispatch, Opts, []),
	MaxEmptyLines = proplists:get_value(max_empty_lines, Opts, 5),
	Timeout = proplists:get_value(timeout, Opts, 5000),
	wait_request(#state{socket=Socket, transport=Transport,
		dispatch=Dispatch, max_empty_lines=MaxEmptyLines, timeout=Timeout}).

-spec parse_request(State::#state{}) -> ok.
%% @todo Use decode_packet options to limit length?
parse_request(State=#state{buffer=Buffer}) ->
	case erlang:decode_packet(http_bin, Buffer, []) of
		{ok, Request, Rest} -> request(Request, State#state{buffer=Rest});
		{more, _Length} -> wait_request(State);
		{error, _Reason} -> error_response(400, State)
	end.

-spec wait_request(State::#state{}) -> ok.
wait_request(State=#state{socket=Socket, transport=Transport,
		timeout=T, buffer=Buffer}) ->
	case Transport:recv(Socket, 0, T) of
		{ok, Data} -> parse_request(State#state{
			buffer= << Buffer/binary, Data/binary >>});
		{error, timeout} -> error_terminate(408, State);
		{error, closed} -> terminate(State)
	end.

-spec request({http_request, Method::http_method(), URI::http_uri(),
	Version::http_version()}, State::#state{}) -> ok.
%% @todo We probably want to handle some things differently between versions.
request({http_request, _Method, _URI, Version}, State)
		when Version =/= {1, 0}, Version =/= {1, 1} ->
	error_terminate(505, State);
%% @todo We need to cleanup the URI properly.
request({http_request, Method, {abs_path, AbsPath}, Version},
		State=#state{socket=Socket, transport=Transport}) ->
	{Path, RawPath, Qs} = cowboy_dispatcher:split_path(AbsPath),
	ConnAtom = version_to_connection(Version),
	parse_header(#http_req{socket=Socket, transport=Transport,
		connection=ConnAtom, method=Method, version=Version,
		path=Path, raw_path=RawPath, raw_qs=Qs},
		State#state{connection=ConnAtom});
request({http_request, Method, '*', Version},
		State=#state{socket=Socket, transport=Transport}) ->
	ConnAtom = version_to_connection(Version),
	parse_header(#http_req{socket=Socket, transport=Transport,
		connection=ConnAtom, method=Method, version=Version,
		path='*', raw_path= <<"*">>, raw_qs= <<>>},
		State#state{connection=ConnAtom});
request({http_request, _Method, _URI, _Version}, State) ->
	error_terminate(501, State);
request({http_error, <<"\r\n">>},
		State=#state{req_empty_lines=N, max_empty_lines=N}) ->
	error_terminate(400, State);
request({http_error, <<"\r\n">>}, State=#state{req_empty_lines=N}) ->
	parse_request(State#state{req_empty_lines=N + 1});
request({http_error, _Any}, State) ->
	error_terminate(400, State).

-spec parse_header(Req::#http_req{}, State::#state{}) -> ok.
parse_header(Req, State=#state{buffer=Buffer}) ->
	case erlang:decode_packet(httph_bin, Buffer, []) of
		{ok, Header, Rest} -> header(Header, Req, State#state{buffer=Rest});
		{more, _Length} -> wait_header(Req, State);
		{error, _Reason} -> error_response(400, State)
	end.

-spec wait_header(Req::#http_req{}, State::#state{}) -> ok.
wait_header(Req, State=#state{socket=Socket,
		transport=Transport, timeout=T, buffer=Buffer}) ->
	case Transport:recv(Socket, 0, T) of
		{ok, Data} -> parse_header(Req, State#state{
			buffer= << Buffer/binary, Data/binary >>});
		{error, timeout} -> error_terminate(408, State);
		{error, closed} -> terminate(State)
	end.

-spec header({http_header, I::integer(), Field::http_header(), R::term(),
	Value::binary()} | http_eoh, Req::#http_req{}, State::#state{}) -> ok.
header({http_header, _I, 'Host', _R, RawHost}, Req=#http_req{
		transport=Transport, host=undefined}, State) ->
	RawHost2 = binary_to_lower(RawHost),
	case catch cowboy_dispatcher:split_host(RawHost2) of
		{Host, RawHost3, undefined} ->
			Port = default_port(Transport:name()),
			dispatch(Req#http_req{host=Host, raw_host=RawHost3, port=Port,
				headers=[{'Host', RawHost3}|Req#http_req.headers]}, State);
		{Host, RawHost3, Port} ->
			dispatch(Req#http_req{host=Host, raw_host=RawHost3, port=Port,
				headers=[{'Host', RawHost3}|Req#http_req.headers]}, State);
		{'EXIT', _Reason} ->
			error_terminate(400, State)
	end;
%% Ignore Host headers if we already have it.
header({http_header, _I, 'Host', _R, _V}, Req, State) ->
	parse_header(Req, State);
header({http_header, _I, 'Connection', _R, Connection}, Req, State) ->
	ConnAtom = connection_to_atom(Connection),
	parse_header(Req#http_req{connection=ConnAtom,
		headers=[{'Connection', Connection}|Req#http_req.headers]},
		State#state{connection=ConnAtom});
header({http_header, _I, Field, _R, Value}, Req, State) ->
	parse_header(Req#http_req{headers=[{Field, Value}|Req#http_req.headers]},
		State);
%% The Host header is required.
header(http_eoh, #http_req{host=undefined}, State) ->
	error_terminate(400, State);
header(http_eoh, Req, State=#state{buffer=Buffer}) ->
	handler_init(Req#http_req{buffer=Buffer}, State#state{buffer= <<>>});
header({http_error, _Bin}, _Req, State) ->
	error_terminate(500, State).

-spec dispatch(Req::#http_req{}, State::#state{}) -> ok.
dispatch(Req=#http_req{host=Host, path=Path},
		State=#state{dispatch=Dispatch}) ->
	%% @todo We probably want to filter the Host and Path here to allow
	%%       things like url rewriting.
	case cowboy_dispatcher:match(Host, Path, Dispatch) of
		{ok, Handler, Opts, Binds, HostInfo, PathInfo} ->
			parse_header(Req#http_req{host_info=HostInfo, path_info=PathInfo,
				bindings=Binds},
				State#state{handler={Handler, Opts}});
		{error, notfound, host} ->
			error_terminate(400, State);
		{error, notfound, path} ->
			error_terminate(404, State)
	end.

-spec handler_init(Req::#http_req{}, State::#state{}) -> ok.
handler_init(Req, State=#state{
		transport=Transport, handler={Handler, Opts}}) ->
	case catch Handler:init({Transport:name(), http}, Req, Opts) of
		{ok, Req2, HandlerState} ->
			handler_loop(HandlerState, Req2, State);
		%% @todo {upgrade, transport, Module}
		{upgrade, protocol, Module} ->
			Module:upgrade(Handler, Opts, Req);
		{'EXIT', _Reason} ->
			error_terminate(500, State)
	end.

-spec handler_loop(HandlerState::term(), Req::#http_req{},
	State::#state{}) -> ok.
handler_loop(HandlerState, Req, State=#state{handler={Handler, _Opts}}) ->
	case catch Handler:handle(Req#http_req{resp_state=waiting},
			HandlerState) of
		{ok, Req2, HandlerState2} ->
			handler_terminate(HandlerState2, Req2, State);
		{'EXIT', _Reason} ->
			terminate(State)
	end.

-spec handler_terminate(HandlerState::term(), Req::#http_req{},
	State::#state{}) -> ok.
handler_terminate(HandlerState, Req=#http_req{buffer=Buffer},
		State=#state{handler={Handler, _Opts}}) ->
	HandlerRes = (catch Handler:terminate(
		Req#http_req{resp_state=locked}, HandlerState)),
	BodyRes = ensure_body_processed(Req),
	RespRes = ensure_response(Req, State),
	case {HandlerRes, BodyRes, RespRes, State#state.connection} of
		{ok, ok, ok, keepalive} ->
			?MODULE:parse_request(State#state{buffer=Buffer});
		_Closed ->
			terminate(State)
	end.

-spec ensure_body_processed(Req::#http_req{}) -> ok | close.
ensure_body_processed(#http_req{body_state=done}) ->
	ok;
ensure_body_processed(Req=#http_req{body_state=waiting}) ->
	case cowboy_http_req:body(Req) of
		{error, badarg} -> ok; %% No body.
		{error, _Reason} -> close;
		_Any -> ok
	end.

-spec ensure_response(Req::#http_req{}, State::#state{}) -> ok.
%% The handler has already fully replied to the client.
ensure_response(#http_req{resp_state=done}, _State) ->
	ok;
%% No response has been sent but everything apparently went fine.
%% Reply with 204 No Content to indicate this.
ensure_response(#http_req{resp_state=waiting}, State) ->
	error_response(204, State);
%% Close the chunked reply.
ensure_response(#http_req{socket=Socket, transport=Transport,
		resp_state=chunks}, _State) ->
	Transport:send(Socket, <<"0\r\n\r\n">>),
	close.

-spec error_response(Code::http_status(), State::#state{}) -> ok.
error_response(Code, #state{socket=Socket,
		transport=Transport, connection=Connection}) ->
	_ = cowboy_http_req:reply(Code, [], [], #http_req{
		socket=Socket, transport=Transport,
		connection=Connection, resp_state=waiting}),
	ok.

-spec error_terminate(Code::http_status(), State::#state{}) -> ok.
error_terminate(Code, State) ->
	error_response(Code, State#state{connection=close}),
	terminate(State).

-spec terminate(State::#state{}) -> ok.
terminate(#state{socket=Socket, transport=Transport}) ->
	Transport:close(Socket),
	ok.

%% Internal.

-spec version_to_connection(Version::http_version()) -> keepalive | close.
version_to_connection({1, 1}) -> keepalive;
version_to_connection(_Any) -> close.

-spec connection_to_atom(Connection::binary()) -> keepalive | close.
connection_to_atom(<<"keep-alive">>) ->
	keepalive;
connection_to_atom(<<"close">>) ->
	close;
connection_to_atom(Connection) ->
	case binary_to_lower(Connection) of
		<<"close">> -> close;
		_Any -> keepalive
	end.

-spec default_port(TransportName::atom()) -> 80 | 443.
default_port(ssl) -> 443;
default_port(_) -> 80.

%% We are excluding a few characters on purpose.
-spec binary_to_lower(binary()) -> binary().
binary_to_lower(L) ->
	<< << (char_to_lower(C)) >> || << C >> <= L >>.

%% We gain noticeable speed by matching each value directly.
-spec char_to_lower(char()) -> char().
char_to_lower($A) -> $a;
char_to_lower($B) -> $b;
char_to_lower($C) -> $c;
char_to_lower($D) -> $d;
char_to_lower($E) -> $e;
char_to_lower($F) -> $f;
char_to_lower($G) -> $g;
char_to_lower($H) -> $h;
char_to_lower($I) -> $i;
char_to_lower($J) -> $j;
char_to_lower($K) -> $k;
char_to_lower($L) -> $l;
char_to_lower($M) -> $m;
char_to_lower($N) -> $n;
char_to_lower($O) -> $o;
char_to_lower($P) -> $p;
char_to_lower($Q) -> $q;
char_to_lower($R) -> $r;
char_to_lower($S) -> $s;
char_to_lower($T) -> $t;
char_to_lower($U) -> $u;
char_to_lower($V) -> $v;
char_to_lower($W) -> $w;
char_to_lower($X) -> $x;
char_to_lower($Y) -> $y;
char_to_lower($Z) -> $z;
char_to_lower(Ch) -> Ch.
