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

-module(cowboy_http_req).

-export([
	method/1, version/1, peer/1,
	host/1, host_info/1, raw_host/1, port/1,
	path/1, path_info/1, raw_path/1,
	qs_val/2, qs_val/3, qs_vals/1, raw_qs/1,
	binding/2, binding/3, bindings/1,
	header/2, header/3, headers/1
%%	cookie/2, cookie/3, cookies/1 @todo
]). %% Request API.

-export([
	body/1, body/2, body_qs/1
]). %% Request Body API.

-export([
	reply/4, chunked_reply/3, chunk/2
]). %% Response API.

-include("include/http.hrl").
-include_lib("eunit/include/eunit.hrl").

%% Request API.

-spec method(Req::#http_req{}) -> {Method::http_method(), Req::#http_req{}}.
method(Req) ->
	{Req#http_req.method, Req}.

-spec version(Req::#http_req{}) -> {Version::http_version(), Req::#http_req{}}.
version(Req) ->
	{Req#http_req.version, Req}.

-spec peer(Req::#http_req{})
	-> {{Address::ip_address(), Port::ip_port()}, Req::#http_req{}}.
peer(Req=#http_req{socket=Socket, transport=Transport, peer=undefined}) ->
	{ok, Peer} = Transport:peername(Socket),
	{Peer, Req#http_req{peer=Peer}};
peer(Req) ->
	{Req#http_req.peer, Req}.

-spec host(Req::#http_req{})
	-> {Host::cowboy_dispatcher:path_tokens(), Req::#http_req{}}.
host(Req) ->
	{Req#http_req.host, Req}.

-spec host_info(Req::#http_req{})
	-> {HostInfo::cowboy_dispatcher:path_tokens() | undefined,
		Req::#http_req{}}.
host_info(Req) ->
	{Req#http_req.host_info, Req}.

-spec raw_host(Req::#http_req{}) -> {RawHost::binary(), Req::#http_req{}}.
raw_host(Req) ->
	{Req#http_req.raw_host, Req}.

-spec port(Req::#http_req{}) -> {Port::ip_port(), Req::#http_req{}}.
port(Req) ->
	{Req#http_req.port, Req}.

-spec path(Req::#http_req{})
	-> {Path::cowboy_dispatcher:path_tokens(), Req::#http_req{}}.
path(Req) ->
	{Req#http_req.path, Req}.

-spec path_info(Req::#http_req{})
	-> {PathInfo::cowboy_dispatcher:path_tokens() | undefined,
		Req::#http_req{}}.
path_info(Req) ->
	{Req#http_req.path_info, Req}.

-spec raw_path(Req::#http_req{}) -> {RawPath::binary(), Req::#http_req{}}.
raw_path(Req) ->
	{Req#http_req.raw_path, Req}.

-spec qs_val(Name::binary(), Req::#http_req{})
	-> {Value::binary() | true | undefined, Req::#http_req{}}.
%% @equiv qs_val(Name, Req) -> qs_val(Name, Req, undefined)
qs_val(Name, Req) ->
	qs_val(Name, Req, undefined).

-spec qs_val(Name::binary(), Req::#http_req{}, Default)
	-> {Value::binary() | true | Default, Req::#http_req{}}
	when Default::term().
qs_val(Name, Req=#http_req{raw_qs=RawQs, qs_vals=undefined}, Default) ->
	QsVals = parse_qs(RawQs),
	qs_val(Name, Req#http_req{qs_vals=QsVals}, Default);
qs_val(Name, Req, Default) ->
	case lists:keyfind(Name, 1, Req#http_req.qs_vals) of
		{Name, Value} -> {Value, Req};
		false -> {Default, Req}
	end.

-spec qs_vals(Req::#http_req{})
	-> {list({Name::binary(), Value::binary() | true}), Req::#http_req{}}.
qs_vals(Req=#http_req{raw_qs=RawQs, qs_vals=undefined}) ->
	QsVals = parse_qs(RawQs),
	qs_vals(Req#http_req{qs_vals=QsVals});
qs_vals(Req=#http_req{qs_vals=QsVals}) ->
	{QsVals, Req}.

-spec raw_qs(Req::#http_req{}) -> {RawQs::binary(), Req::#http_req{}}.
raw_qs(Req) ->
	{Req#http_req.raw_qs, Req}.

-spec binding(Name::atom(), Req::#http_req{})
	-> {Value::binary() | undefined, Req::#http_req{}}.
%% @equiv binding(Name, Req) -> binding(Name, Req, undefined)
binding(Name, Req) ->
	binding(Name, Req, undefined).

-spec binding(Name::atom(), Req::#http_req{}, Default)
	-> {Value::binary() | Default, Req::#http_req{}} when Default::term().
binding(Name, Req, Default) ->
	case lists:keyfind(Name, 1, Req#http_req.bindings) of
		{Name, Value} -> {Value, Req};
		false -> {Default, Req}
	end.

-spec bindings(Req::#http_req{})
	-> {list({Name::atom(), Value::binary()}), Req::#http_req{}}.
bindings(Req) ->
	{Req#http_req.bindings, Req}.

-spec header(Name::atom() | binary(), Req::#http_req{})
	-> {Value::binary() | undefined, Req::#http_req{}}.
%% @equiv header(Name, Req) -> header(Name, Req, undefined)
header(Name, Req) ->
	header(Name, Req, undefined).

-spec header(Name::atom() | binary(), Req::#http_req{}, Default)
	-> {Value::binary() | Default, Req::#http_req{}} when Default::term().
header(Name, Req, Default) ->
	case lists:keyfind(Name, 1, Req#http_req.headers) of
		{Name, Value} -> {Value, Req};
		false -> {Default, Req}
	end.

-spec headers(Req::#http_req{})
	-> {Headers::http_headers(), Req::#http_req{}}.
headers(Req) ->
	{Req#http_req.headers, Req}.

%% Request Body API.

%% @todo We probably want to allow a max length.
-spec body(Req::#http_req{})
	-> {ok, Body::binary(), Req::#http_req{}} | {error, Reason::atom()}.
body(Req) ->
	{Length, Req2} = cowboy_http_req:header('Content-Length', Req),
	case Length of
		undefined -> {error, badarg};
		_Any ->
			Length2 = list_to_integer(binary_to_list(Length)),
			body(Length2, Req2)
	end.

%% @todo We probably want to configure the timeout.
-spec body(Length::non_neg_integer(), Req::#http_req{})
	-> {ok, Body::binary(), Req::#http_req{}} | {error, Reason::atom()}.
body(Length, Req=#http_req{body_state=waiting, buffer=Buffer})
		when Length =:= byte_size(Buffer) ->
	{ok, Buffer, Req#http_req{body_state=done, buffer= <<>>}};
body(Length, Req=#http_req{socket=Socket, transport=Transport,
		body_state=waiting, buffer=Buffer}) when Length > byte_size(Buffer) ->
	case Transport:recv(Socket, Length - byte_size(Buffer), 5000) of
		{ok, Body} -> {ok, << Buffer/binary, Body/binary >>, Req#http_req{body_state=done, buffer= <<>>}};
		{error, Reason} -> {error, Reason}
	end.

-spec body_qs(Req::#http_req{})
	-> {list({Name::binary(), Value::binary() | true}), Req::#http_req{}}.
body_qs(Req) ->
	{ok, Body, Req2} = body(Req),
	{parse_qs(Body), Req2}.

%% Response API.

-spec reply(Code::http_status(), Headers::http_headers(),
	Body::iodata(), Req::#http_req{}) -> {ok, Req::#http_req{}}.
reply(Code, Headers, Body, Req=#http_req{socket=Socket,
		transport=Transport, connection=Connection,
		resp_state=waiting}) ->
	Head = response_head(Code, Headers, [
		{<<"Connection">>, atom_to_connection(Connection)},
		{<<"Content-Length">>,
			list_to_binary(integer_to_list(iolist_size(Body)))},
		{<<"Date">>, cowboy_clock:rfc1123()},
		{<<"Server">>, <<"Cowboy">>}
	]),
	Transport:send(Socket, [Head, Body]),
	{ok, Req#http_req{resp_state=done}}.

-spec chunked_reply(Code::http_status(), Headers::http_headers(),
	Req::#http_req{}) -> {ok, Req::#http_req{}}.
chunked_reply(Code, Headers, Req=#http_req{socket=Socket, transport=Transport,
		resp_state=waiting}) ->
	Head = response_head(Code, Headers, [
		{<<"Connection">>, <<"close">>},
		{<<"Transfer-Encoding">>, <<"chunked">>},
		{<<"Date">>, cowboy_clock:rfc1123()},
		{<<"Server">>, <<"Cowboy">>}
	]),
	Transport:send(Socket, Head),
	{ok, Req#http_req{resp_state=chunks}}.

-spec chunk(Data::iodata(), Req::#http_req{}) -> ok.
chunk(Data, #http_req{socket=Socket, transport=Transport, resp_state=chunks}) ->
	Transport:send(Socket, [integer_to_list(iolist_size(Data), 16),
		<<"\r\n">>, Data, <<"\r\n">>]).

%% Internal.

-spec parse_qs(Qs::binary()) -> list({Name::binary(), Value::binary() | true}).
parse_qs(<<>>) ->
	[];
parse_qs(Qs) ->
	Tokens = binary:split(Qs, <<"&">>, [global, trim]),
	[case binary:split(Token, <<"=">>) of
		[Token] -> {Token, true};
		[Name, Value] -> {Name, Value}
	end || Token <- Tokens].

-spec response_head(Code::http_status(), Headers::http_headers(),
	DefaultHeaders::http_headers()) -> iolist().
response_head(Code, Headers, DefaultHeaders) ->
	StatusLine = <<"HTTP/1.1 ", (status(Code))/binary, "\r\n">>,
	Headers2 = [{header_to_binary(Key), Value} || {Key, Value} <- Headers],
	Headers3 = lists:keysort(1, Headers2),
	Headers4 = lists:ukeymerge(1, Headers3, DefaultHeaders),
	Headers5 = [<< Key/binary, ": ", Value/binary, "\r\n" >>
		|| {Key, Value} <- Headers4],
	[StatusLine, Headers5, <<"\r\n">>].

-spec atom_to_connection(Atom::keepalive | close) -> binary().
atom_to_connection(keepalive) ->
	<<"keep-alive">>;
atom_to_connection(close) ->
	<<"close">>.

-spec status(Code::http_status()) -> binary().
status(100) -> <<"100 Continue">>;
status(101) -> <<"101 Switching Protocols">>;
status(102) -> <<"102 Processing">>;
status(200) -> <<"200 OK">>;
status(201) -> <<"201 Created">>;
status(202) -> <<"202 Accepted">>;
status(203) -> <<"203 Non-Authoritative Information">>;
status(204) -> <<"204 No Content">>;
status(205) -> <<"205 Reset Content">>;
status(206) -> <<"206 Partial Content">>;
status(207) -> <<"207 Multi-Status">>;
status(226) -> <<"226 IM Used">>;
status(300) -> <<"300 Multiple Choices">>;
status(301) -> <<"301 Moved Permanently">>;
status(302) -> <<"302 Found">>;
status(303) -> <<"303 See Other">>;
status(304) -> <<"304 Not Modified">>;
status(305) -> <<"305 Use Proxy">>;
status(306) -> <<"306 Switch Proxy">>;
status(307) -> <<"307 Temporary Redirect">>;
status(400) -> <<"400 Bad Request">>;
status(401) -> <<"401 Unauthorized">>;
status(402) -> <<"402 Payment Required">>;
status(403) -> <<"403 Forbidden">>;
status(404) -> <<"404 Not Found">>;
status(405) -> <<"405 Method Not Allowed">>;
status(406) -> <<"406 Not Acceptable">>;
status(407) -> <<"407 Proxy Authentication Required">>;
status(408) -> <<"408 Request Timeout">>;
status(409) -> <<"409 Conflict">>;
status(410) -> <<"410 Gone">>;
status(411) -> <<"411 Length Required">>;
status(412) -> <<"412 Precondition Failed">>;
status(413) -> <<"413 Request Entity Too Large">>;
status(414) -> <<"414 Request-URI Too Long">>;
status(415) -> <<"415 Unsupported Media Type">>;
status(416) -> <<"416 Requested Range Not Satisfiable">>;
status(417) -> <<"417 Expectation Failed">>;
status(418) -> <<"418 I'm a teapot">>;
status(422) -> <<"422 Unprocessable Entity">>;
status(423) -> <<"423 Locked">>;
status(424) -> <<"424 Failed Dependency">>;
status(425) -> <<"425 Unordered Collection">>;
status(426) -> <<"426 Upgrade Required">>;
status(500) -> <<"500 Internal Server Error">>;
status(501) -> <<"501 Not Implemented">>;
status(502) -> <<"502 Bad Gateway">>;
status(503) -> <<"503 Service Unavailable">>;
status(504) -> <<"504 Gateway Timeout">>;
status(505) -> <<"505 HTTP Version Not Supported">>;
status(506) -> <<"506 Variant Also Negotiates">>;
status(507) -> <<"507 Insufficient Storage">>;
status(510) -> <<"510 Not Extended">>;
status(B) when is_binary(B) -> B.

-spec header_to_binary(http_header()) -> binary().
header_to_binary('Cache-Control') -> <<"Cache-Control">>;
header_to_binary('Connection') -> <<"Connection">>;
header_to_binary('Date') -> <<"Date">>;
header_to_binary('Pragma') -> <<"Pragma">>;
header_to_binary('Transfer-Encoding') -> <<"Transfer-Encoding">>;
header_to_binary('Upgrade') -> <<"Upgrade">>;
header_to_binary('Via') -> <<"Via">>;
header_to_binary('Accept') -> <<"Accept">>;
header_to_binary('Accept-Charset') -> <<"Accept-Charset">>;
header_to_binary('Accept-Encoding') -> <<"Accept-Encoding">>;
header_to_binary('Accept-Language') -> <<"Accept-Language">>;
header_to_binary('Authorization') -> <<"Authorization">>;
header_to_binary('From') -> <<"From">>;
header_to_binary('Host') -> <<"Host">>;
header_to_binary('If-Modified-Since') -> <<"If-Modified-Since">>;
header_to_binary('If-Match') -> <<"If-Match">>;
header_to_binary('If-None-Match') -> <<"If-None-Match">>;
header_to_binary('If-Range') -> <<"If-Range">>;
header_to_binary('If-Unmodified-Since') -> <<"If-Unmodified-Since">>;
header_to_binary('Max-Forwards') -> <<"Max-Forwards">>;
header_to_binary('Proxy-Authorization') -> <<"Proxy-Authorization">>;
header_to_binary('Range') -> <<"Range">>;
header_to_binary('Referer') -> <<"Referer">>;
header_to_binary('User-Agent') -> <<"User-Agent">>;
header_to_binary('Age') -> <<"Age">>;
header_to_binary('Location') -> <<"Location">>;
header_to_binary('Proxy-Authenticate') -> <<"Proxy-Authenticate">>;
header_to_binary('Public') -> <<"Public">>;
header_to_binary('Retry-After') -> <<"Retry-After">>;
header_to_binary('Server') -> <<"Server">>;
header_to_binary('Vary') -> <<"Vary">>;
header_to_binary('Warning') -> <<"Warning">>;
header_to_binary('Www-Authenticate') -> <<"Www-Authenticate">>;
header_to_binary('Allow') -> <<"Allow">>;
header_to_binary('Content-Base') -> <<"Content-Base">>;
header_to_binary('Content-Encoding') -> <<"Content-Encoding">>;
header_to_binary('Content-Language') -> <<"Content-Language">>;
header_to_binary('Content-Length') -> <<"Content-Length">>;
header_to_binary('Content-Location') -> <<"Content-Location">>;
header_to_binary('Content-Md5') -> <<"Content-Md5">>;
header_to_binary('Content-Range') -> <<"Content-Range">>;
header_to_binary('Content-Type') -> <<"Content-Type">>;
header_to_binary('Etag') -> <<"Etag">>;
header_to_binary('Expires') -> <<"Expires">>;
header_to_binary('Last-Modified') -> <<"Last-Modified">>;
header_to_binary('Accept-Ranges') -> <<"Accept-Ranges">>;
header_to_binary('Set-Cookie') -> <<"Set-Cookie">>;
header_to_binary('Set-Cookie2') -> <<"Set-Cookie2">>;
header_to_binary('X-Forwarded-For') -> <<"X-Forwarded-For">>;
header_to_binary('Cookie') -> <<"Cookie">>;
header_to_binary('Keep-Alive') -> <<"Keep-Alive">>;
header_to_binary('Proxy-Connection') -> <<"Proxy-Connection">>;
header_to_binary(B) when is_binary(B) -> B.

%% Tests.

-ifdef(TEST).

parse_qs_test_() ->
	%% {Qs, Result}
	Tests = [
		{<<"">>, []},
		{<<"a=b">>, [{<<"a">>, <<"b">>}]},
		{<<"aaa=bbb">>, [{<<"aaa">>, <<"bbb">>}]},
		{<<"a&b">>, [{<<"a">>, true}, {<<"b">>, true}]},
		{<<"a=b&c&d=e">>, [{<<"a">>, <<"b">>}, {<<"c">>, true}, {<<"d">>, <<"e">>}]},
		{<<"a=b=c=d=e&f=g">>, [{<<"a">>, <<"b=c=d=e">>}, {<<"f">>, <<"g">>}]}
	],
	[{Qs, fun() -> R = parse_qs(Qs) end} || {Qs, R} <- Tests].

-endif.
