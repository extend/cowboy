%% Copyright (c) 2013-2014, Loïc Hoguin <essen@ninenines.eu>
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

-module(cowboy_spdy).

%% API.
-export([start_link/4]).

%% Internal.
-export([init/5]).
-export([system_continue/3]).
-export([system_terminate/4]).
-export([system_code_change/4]).

%% Internal request process.
-export([request_init/11]).
-export([resume/5]).
-export([reply/4]).
-export([stream_reply/3]).
-export([stream_data/2]).
-export([stream_close/1]).

%% Internal transport functions.
-export([name/0]).
-export([messages/0]).
-export([recv/3]).
-export([send/2]).
-export([sendfile/2]).
-export([setopts/2]).

-export([push_reply/7]).

-type streamid() :: non_neg_integer().
-type socket() :: {pid(), streamid()}.

-define(SESSION, 0).
-define(INITIAL_WINDOW_SIZE, 16 * 1024 * 1024).

-record(flow_control, {
    initial_send_window = 65536 :: integer(),
    initial_recv_window = ?INITIAL_WINDOW_SIZE :: integer(),
    send_window = 65536 :: integer(),
    recv_window = ?INITIAL_WINDOW_SIZE :: integer()
}).

-record(child, {
	streamid :: streamid(),
	pid :: pid(),
	input = nofin :: fin | nofin,
	in_buffer = <<>> :: binary(),
	is_recv = false :: false | {active, socket(), pid()}
		| {passive, socket(), pid(), non_neg_integer(), reference()},
	output = nofin :: fin | nofin,
    flow_control = #flow_control{} :: #flow_control{}
}).

-record(state, {
	parent = undefined :: pid(),
	socket,
	transport,
	buffer = <<>> :: binary(),
	middlewares,
	env,
	onrequest,
	onresponse,
	peer,
	zdef,
	zinf,
	last_streamid = 0 :: streamid(),
    last_unidirectional_streamid = 0,
	children = [] :: [#child{}],
    flow_control = #flow_control{} :: #flow_control{}
}).


%% FLOW_CONTROL
%%
%% 1. Open connection
%% 2. Send settings and set initial_recv_window_size
%% 3. Maybe receive settings and update initial_send_window_size -- can happen at any time
%%
%% When receiving frames:
%%
%% 1. update_stream_recv_window_size(Child, -DataSize)
%%
%% 2. if (new_size < initial_size/2.0):
%%        update_stream_recv_window_size(new_size) %% Also sends a WINDOW_UPDATE frame
%%
%%    update_session_recv_window_size(State, -DataSize)
%%
%%    if (new_size < initial_size/2.0):
%%        update_session_recv_window_size(new_size) %% Also sends WINDOW_UPDATE frame
%%
%% When sending frames:
%%   MAX_SIZE_TO_SEND = MIN(stream.send_window, session.send_window)
%%   send(Data, MAX_SIZE_TO_SEND).
%%
%% WINDOW_UPDATE:
%%   Update window size
%%   Per_connection:
%%     trigger sends on all channels
%%   Per_stream:
%%     trigger send on stream

-type opts() :: [{env, cowboy_middleware:env()}
	| {middlewares, [module()]}
	| {onrequest, cowboy:onrequest_fun()}
	| {onresponse, cowboy:onresponse_fun()}].
-export_type([opts/0]).

%% API.

-spec start_link(any(), inet:socket(), module(), any()) -> {ok, pid()}.
start_link(Ref, Socket, Transport, Opts) ->
	proc_lib:start_link(?MODULE, init,
		[self(), Ref, Socket, Transport, Opts]).

%% Internal.

%% Faster alternative to proplists:get_value/3.
get_value(Key, Opts, Default) ->
	case lists:keyfind(Key, 1, Opts) of
		{_, Value} -> Value;
		_ -> Default
	end.

-spec init(pid(), ranch:ref(), inet:socket(), module(), opts()) -> ok.
init(Parent, Ref, Socket, Transport, Opts) ->
	process_flag(trap_exit, true),
	ok = proc_lib:init_ack(Parent, {ok, self()}),
	{ok, Peer} = Transport:peername(Socket),
	Middlewares = get_value(middlewares, Opts, [cowboy_router, cowboy_handler]),
	Env = [{listener, Ref}|get_value(env, Opts, [])] ++ [{raw_socket, Socket}],
	OnRequest = get_value(onrequest, Opts, undefined),
	OnResponse = get_value(onresponse, Opts, undefined),
	Zdef = cow_spdy:deflate_init(),
	Zinf = cow_spdy:inflate_init(),
	ok = ranch:accept_ack(Ref),
    Transport:send(Socket, settings_frame(?INITIAL_WINDOW_SIZE)),
    %% Send initial window size in a settings frame
	loop(#state{parent=Parent, socket=Socket, transport=Transport,
		middlewares=Middlewares, env=Env, onrequest=OnRequest,
		onresponse=OnResponse, peer=Peer, zdef=Zdef, zinf=Zinf}).

parse_frame(State=#state{zinf=Zinf}, Data) ->
	case cow_spdy:split(Data) of
		{true, Frame, Rest} ->
			P = cow_spdy:parse(Frame, Zinf),
			State2 = handle_frame(State#state{buffer = Rest}, P),
			parse_frame(State2, Rest);
		false ->
			loop(State#state{buffer=Data})
	end.

loop(State=#state{parent=Parent, socket=Socket, transport=Transport,
		buffer=Buffer, children=Children}) ->
	{OK, Closed, Error} = Transport:messages(),
	Transport:setopts(Socket, [{active, once}]),
	receive
		{OK, Socket, Data} ->
			Data2 = << Buffer/binary, Data/binary >>,
			parse_frame(State, Data2);
		{Closed, Socket} ->
			terminate(State);
		{Error, Socket, _Reason} ->
			terminate(State);
		{recv, FromSocket = {Pid, StreamID}, FromPid, Length, Timeout}
				when Pid =:= self() ->
            %% Length is the buffering limit
            %% send window updates until this limit is reached?
			Child = #child{in_buffer=InBuffer, is_recv=false}
				= get_child(StreamID, State),
			if
				Length =:= 0, InBuffer =/= <<>> ->
					FromPid ! {recv, FromSocket, {ok, InBuffer}},
					loop(replace_child(Child#child{in_buffer= <<>>}, State));
				byte_size(InBuffer) >= Length ->
                    %% All requested data got buffered here
					<< Data:Length/binary, Rest/binary >> = InBuffer,
    				FromPid ! {recv, FromSocket, {ok, Data}},
					loop(replace_child(Child#child{in_buffer=Rest}, State));
				true ->
					TRef = erlang:send_after(Timeout, self(),
						{recv_timeout, FromSocket}),
					loop(replace_child(Child#child{
						is_recv={passive, FromSocket, FromPid, Length, TRef}},
                        State))
			end;
		{recv_timeout, {Pid, StreamID}}
				when Pid =:= self() ->
			Child = #child{is_recv={passive, FromSocket, FromPid, _, _}}
				= get_child(StreamID, State),
			FromPid ! {recv, FromSocket, {error, timeout}},
			loop(replace_child(Child#child{is_recv=false}, State));
		{reply, {Pid, StreamID}, Status, Headers}
				when Pid =:= self() ->
			Child = #child{output=nofin} = get_child(StreamID, State),
			syn_reply(State, StreamID, true, Status, Headers),
			loop(replace_child(Child#child{output=fin}, State));
		{reply, {Pid, StreamID}, Status, Headers, Body}
				when Pid =:= self() ->
			Child = #child{output=nofin} = get_child(StreamID, State),
			syn_reply(State, StreamID, false, Status, Headers),
            %% @todo update send window size
            BytesToSend = iolist_size(Body),

            State2 = #state{} = update_send_window(State, -BytesToSend),
            Child2 = #child{} = update_send_window(Child, -BytesToSend),

            %% Also update childs send window....
			data(State2, StreamID, true, Body),
			loop(replace_child(Child2#child{output=fin}, State2));
        %%Pid ! {push_reply, self(), Socket, Method, Host, Path, Status, Headers, Body},
        {push_reply, From, {Pid, AssocStreamID}, Method, Host, Path, Status, Headers, Body}
                when Pid =:= self() ->
            %% Make sure that the original stream is still open
            #child{output=nofin} = get_child(AssocStreamID, State),
            {ok, StreamID, State2} = next_unidirectional_stream_id(State),
            syn_stream(State2, StreamID, AssocStreamID, Host, Method,
                       Path, false, Status, Headers),
            data(State2, StreamID, true, Body),
            From ! {stream_id, StreamID},
            loop(State2);

		{stream_reply, {Pid, StreamID}, Status, Headers}
				when Pid =:= self() ->
			#child{output=nofin} = get_child(StreamID, State),
			syn_reply(State, StreamID, false, Status, Headers),
			loop(State);
		{stream_data, {Pid, StreamID}, Data}
				when Pid =:= self() ->
            %% @todo respect output window size
            %% stop sending and restart if needed
            %% get_max_send_size(Child, State) ->
            %%     Check both flow control status
            %% If data already in buffer just append
            %% Sends get triggered by window_update frames
			#child{output=nofin} = get_child(StreamID, State),
			data(State, StreamID, false, Data),
			loop(State);
		{stream_close, {Pid, StreamID}}
				when Pid =:= self() ->
			Child = #child{output=nofin} = get_child(StreamID, State),
			data(State, StreamID, true, <<>>),
			loop(replace_child(Child#child{output=fin}, State));
        {rst_stream, StreamID, Status} ->
			Child = #child{output=nofin} = get_child(StreamID, State),
            rst_stream(State, StreamID, Status),
			loop(replace_child(Child#child{output=fin}, State));
    
		{sendfile, {Pid, StreamID}, Filepath}
				when Pid =:= self() ->
			Child = #child{output=nofin} = get_child(StreamID, State),
			data_from_file(State, StreamID, Filepath),
			loop(replace_child(Child#child{output=fin}, State));
		{active, FromSocket = {Pid, StreamID}, FromPid} when Pid =:= self() ->
			Child = #child{in_buffer=InBuffer, is_recv=false}
				= get_child(StreamID, State),
			case InBuffer of
				<<>> ->
					loop(replace_child(Child#child{
						is_recv={active, FromSocket, FromPid}}, State));
				_ ->
					FromPid ! {spdy, FromSocket, InBuffer},
					loop(replace_child(Child#child{in_buffer= <<>>}, State))
			end;
		{passive, FromSocket = {Pid, StreamID}, FromPid} when Pid =:= self() ->
			Child = #child{is_recv=IsRecv} = get_child(StreamID, State),
			%% Make sure we aren't in the middle of a recv call.
			case IsRecv of false -> ok; {active, FromSocket, FromPid} -> ok end,
			loop(replace_child(Child#child{is_recv=false}, State));
		{'EXIT', Parent, Reason} ->
			exit(Reason);
		{'EXIT', Pid, _} ->
			%% @todo Report the error if any.
			loop(delete_child(Pid, State));
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Parent, ?MODULE, [], State);
		%% Calls from the supervisor module.
		{'$gen_call', {To, Tag}, which_children} ->
			Workers = [{?MODULE, Pid, worker, [?MODULE]}
				|| #child{pid=Pid} <- Children],
			To ! {Tag, Workers},
			loop(State);
		{'$gen_call', {To, Tag}, count_children} ->
			NbChildren = length(Children),
			Counts = [{specs, 1}, {active, NbChildren},
				{supervisors, 0}, {workers, NbChildren}],
			To ! {Tag, Counts},
			loop(State);
		{'$gen_call', {To, Tag}, _} ->
			To ! {Tag, {error, ?MODULE}},
			loop(State)
	after 60000 ->
		goaway(State, ok),
		terminate(State)
	end.

-spec system_continue(_, _, #state{}) -> ok.
system_continue(_, _, State) ->
	loop(State).

-spec system_terminate(any(), _, _, _) -> no_return().
system_terminate(Reason, _, _, _) ->
	exit(Reason).

-spec system_code_change(Misc, _, _, _) -> {ok, Misc} when Misc::#state{}.
system_code_change(Misc, _, _, _) ->
	{ok, Misc}.

%% FLAG_UNIDIRECTIONAL can only be set by the server.
handle_frame(State, {syn_stream, StreamID, _, _, true,
		_, _, _, _, _, _, _}) ->
	rst_stream(State, StreamID, protocol_error),
	State;
%% We do not support Associated-To-Stream-ID.
handle_frame(State, {syn_stream, StreamID, AssocToStreamID,
		_, _, _, _, _, _, _, _, _}) when AssocToStreamID =/= 0 ->
	rst_stream(State, StreamID, internal_error),
	State;
%% SYN_STREAM.
%%
%% Erlang does not allow us to control the priority of processes
%% so we ignore that value entirely.
handle_frame(State=#state{middlewares=Middlewares, env=Env,
		onrequest=OnRequest, onresponse=OnResponse, peer=Peer},
		{syn_stream, StreamID, _, IsFin, _, _,
		Method, _, Host, Path, Version, Headers}) ->
	Pid = spawn_link(?MODULE, request_init, [
		{self(), StreamID}, Peer, OnRequest, OnResponse,
		Env, Middlewares, Method, Host, Path, Version, Headers
	]),
	new_child(State, StreamID, Pid, IsFin);
%% RST_STREAM.
handle_frame(State, {rst_stream, StreamID, Status}) ->
	error_logger:error_msg("Received RST_STREAM frame ~p ~p",
		[StreamID, Status]),
	%% @todo Stop StreamID.
	State;
%% PING initiated by the server; ignore, we don't send any.
handle_frame(State, {ping, PingID}) when PingID rem 2 =:= 0 ->
	error_logger:error_msg("Ignored PING control frame: ~p~n", [PingID]),
	State;
%% PING initiated by the client; send it back.
handle_frame(State=#state{socket=Socket, transport=Transport},
		{ping, PingID}) ->
	Transport:send(Socket, cow_spdy:ping(PingID)),
	State;
%% Data received for a stream.
handle_frame(State, {data, StreamID, IsFin, Data}) ->
    case get_child(StreamID, State) of 
        false -> 
            error_logger:error_msg("Invalid data frame with stream id ~p.", [StreamID]),
            State;
        #child{input=nofin, in_buffer=Buffer, is_recv=IsRecv} = Child ->

            Data2 = << Buffer/binary, Data/binary >>,
            IsFin2 = if IsFin -> fin; true -> nofin end,
            Child2 = case IsRecv of
                         {active, FromSocket, FromPid} ->
                             FromPid ! {spdy, FromSocket, Data},
                             Child#child{input=IsFin2, is_recv=false};
                         {passive, FromSocket, FromPid, 0, TRef} ->
                             FromPid ! {recv, FromSocket, {ok, Data2}},
                             cancel_recv_timeout(StreamID, TRef),
                             Child#child{input=IsFin2, in_buffer= <<>>, is_recv=false};
                         {passive, FromSocket, FromPid, Length, TRef}
                           when byte_size(Data2) >= Length ->
                             << Data3:Length/binary, Rest/binary >> = Data2,
                             FromPid ! {recv, FromSocket, {ok, Data3}},
                             cancel_recv_timeout(StreamID, TRef),
                             Child#child{input=IsFin2, in_buffer=Rest, is_recv=false};
                         _ ->
                             Child#child{input=IsFin2, in_buffer=Data2}
                     end,
            try 
                #state{flow_control=FC} = State,
                InputLength = iolist_size(Data),
                FC2 = update_recv_window_and_maybe_send_window_update(FC, State, ?SESSION, -InputLength),
                #child{flow_control = CFC} = Child2,
                %% Recv window for stream
                CFC2 = update_recv_window_and_maybe_send_window_update(CFC, State, StreamID, -InputLength),
                replace_child(Child2#child{flow_control=CFC2}, State#state{flow_control = FC2}) of

                State2 ->
                    State2
            catch 
                throw:{flow_control, 0} ->
                    %% GOAWAY If the error is in the connection
                    %% RST_STREAM if the error is in the stream
                    error_logger:error_msg("Session recv overflow"),
                    goaway(State, protocol_error),
                    terminate(State);
                throw:{flow_control, StreamID} ->
                    error_logger:error_msg("Stream recv overflow stream_id=~p", [StreamID]),
                    self() ! {rst_stream, StreamID, flow_control_error}, %% Reason
                    replace_child(Child2, State)
            end
    end;

%% General error, can't recover.
handle_frame(State, {error, badprotocol}) ->
	goaway(State, protocol_error),
	terminate(State);

handle_frame(State, {window_update, ?SESSION, WindowSizeDelta}) ->
    case update_send_window(State, WindowSizeDelta) of
        {error, _} ->
            error_logger:error_msg("Invalid window update delta=~p", [WindowSizeDelta]),
            goaway(State, protocol_error),
            terminate(State);
        State2 ->
            %% @todo Trigger sends!
            loop(State2)
    end;

handle_frame(State, {window_update, StreamID, WindowSizeDelta}) ->
    error_logger:error_msg("Updating flow control for stream=~p delta=~p~n", [StreamID, WindowSizeDelta]),
    Child = #child{} = get_child(StreamID, State),
    case update_send_window(Child, WindowSizeDelta) of
        {error, _} ->
            self() ! {rst_stream, StreamID, flow_control_error}, %% Reason
            loop(State);
        Child2 ->
            loop(replace_child(Child2, State))
    end;

handle_frame(State, {settings, _, Settings}) ->
   %% A SETTINGS frame can alter the initial flow control window size for all current streams.
    %% When the value of SETTINGS_INITIAL_WINDOW_SIZE changes, a receiver MUST adjust the size
    %% of all stream flow control windows that it maintains by the difference between the new 
    %% value and the old value. A SETTINGS frame cannot alter the connection flow control window. 
 
    %% 1. Change the initial window size
    %% @todo
    %% 2. Update all currently open streams with the diff between the old and new value
    case lists:keyfind(initial_window_size, 1, Settings) of
        false -> loop(State);
        {_, InitialWindowSize, _, _} ->
            #state{flow_control = FC} = State,
            loop(State#state{flow_control = FC#flow_control{initial_send_window = InitialWindowSize,
                             send_window = InitialWindowSize}})
    end;


handle_frame(State, Frame) ->
	error_logger:error_msg("Ignored frame ~p", [Frame]),
	State.

cancel_recv_timeout(StreamID, TRef) ->
	_ = erlang:cancel_timer(TRef),
	receive
		{recv_timeout, {Pid, StreamID}}
				when Pid =:= self() ->
			ok
	after 0 ->
		ok
	end.

flow_control_new_with_defaults(#flow_control{initial_send_window = ISW, initial_recv_window = IRW}) ->
    #flow_control{initial_send_window = ISW, initial_recv_window = IRW}.

update_recv_window_and_maybe_send_window_update(FlowControl, State, StreamID, Delta) ->
    case update_recv_window(FlowControl, Delta) of
        {error, _} ->
            throw({flow_control, StreamID});
        FlowControl2 ->
            maybe_send_window_update(FlowControl2, State, StreamID)
    end.

%% FLOW_CONTROL
maybe_send_window_update(#flow_control{initial_recv_window = InitialWindowSize,
                                       recv_window = RecvWindowSize} = FC,
                         #state{transport = Transport,
                                socket = Socket}, StreamID)
    when RecvWindowSize =< InitialWindowSize div 2 ->
    error_logger:info_msg("Sending window update streamid=~p old_window_size=~p", [StreamID, RecvWindowSize]),
    Transport:send(Socket, window_update_frame(StreamID, InitialWindowSize - RecvWindowSize)),
    FC#flow_control{recv_window = InitialWindowSize};

maybe_send_window_update(FC, _State, _StreamID) -> FC.

update_recv_window(#flow_control{recv_window = Window}=FC, Delta) ->
    case update_window(Window, Delta) of
        {ok, NewWindow} ->
            FC#flow_control{recv_window = NewWindow};
        {error, Error} ->
            {error, Error}
    end.

update_send_window(#state{flow_control=FC}=State, Delta) ->
    case update_send_window(FC, Delta) of
        {error, Error} ->
            {error, Error};
        FC2 ->
            State#state{flow_control = FC2}
    end;

update_send_window(#child{flow_control=FC}=Child, Delta) ->
    case update_send_window(FC, Delta) of
        {error, Error} ->
            {error, Error};
        FC2 ->
            Child#child{flow_control = FC2}
    end;

update_send_window(#flow_control{send_window = Window}=FC, Delta) ->
    case update_window(Window, Delta) of
        {ok, NewWindow} ->
            FC#flow_control{send_window = NewWindow};
        {error, Error} ->
            {error, Error}
    end.

-spec update_window(integer(), integer()) -> {ok, integer()} | {error, atom()}.

update_window(Window, DeltaValue) ->
    Limit = math:pow(2, 31) - 1,
     case Window + DeltaValue of
       NewWindow when NewWindow =< Limit ->
            error_logger:info_msg("New window: ~p Delta: ~p", [NewWindow, DeltaValue]),
           {ok, NewWindow};
        _ ->
           {error, window_over_limit}
    end.


%% @todo this should really be in cowlib
window_update_frame(StreamID, DeltaWindowSize) ->
    <<1:1, 3:15, 9:16, 0:8, 8:24, 0:1, StreamID:31, 0:1, DeltaWindowSize:31>>.

settings_frame(InitialWindowSize) ->
    KeyPair = <<0:8, 7:24, InitialWindowSize:32>>,
    Length = 4 + 8,
    <<1:1, 3:15, 4:16, 0:7, 0:1, Length:24, 1:32, KeyPair/binary>>.

%% @todo We must wait for the children to finish here,
%% but only up to N milliseconds. Then we shutdown.
terminate(_State) ->
	ok.

next_unidirectional_stream_id(#state{last_unidirectional_streamid = StreamId}=State) ->
    NextStreamId = StreamId + 2,
    %% Max stream_id = pow(2, 31)
    case NextStreamId > 2147483648 of
        true ->
            {error, out_of_streamids};
        _ ->
            {ok, NextStreamId, State#state{last_unidirectional_streamid=NextStreamId}}
    end.

syn_stream(#state{socket=Socket, transport=Transport, zdef=Zdef},
           StreamID, AssocStreamId, Host, Method, Path, IsFin, _Status, Headers) ->
	Frame =	cow_spdy:syn_stream(Zdef,
			    StreamID, AssocStreamId, IsFin, true, 0,
			    Method, <<"https">>, Host, Path, <<"HTTP/1.1">>, Headers),
    Transport:send(Socket, Frame).

syn_reply(#state{socket=Socket, transport=Transport, zdef=Zdef},
		StreamID, IsFin, Status, Headers) ->
	Transport:send(Socket, cow_spdy:syn_reply(Zdef, StreamID, IsFin,
		Status, <<"HTTP/1.1">>, Headers)).

rst_stream(#state{socket=Socket, transport=Transport}, StreamID, Status) ->
	Transport:send(Socket, cow_spdy:rst_stream(StreamID, Status)).

goaway(#state{socket=Socket, transport=Transport, last_streamid=LastStreamID},
		Status) ->
	Transport:send(Socket, cow_spdy:goaway(LastStreamID, Status)).
%% @todo respect send window_size 
data(#state{socket=Socket, transport=Transport}, StreamID, IsFin, Data) ->
	Transport:send(Socket, cow_spdy:data(StreamID, IsFin, Data)).

data_from_file(#state{socket=Socket, transport=Transport},
		StreamID, Filepath) ->
	{ok, IoDevice} = file:open(Filepath, [read, binary, raw]),
	data_from_file(Socket, Transport, StreamID, IoDevice).

data_from_file(Socket, Transport, StreamID, IoDevice) ->
	case file:read(IoDevice, 16#1fff) of
		eof ->
			_ = Transport:send(Socket, cow_spdy:data(StreamID, true, <<>>)),
			ok;
		{ok, Data} ->
			case Transport:send(Socket, cow_spdy:data(StreamID, false, Data)) of
				ok ->
					data_from_file(Socket, Transport, StreamID, IoDevice);
				{error, _} ->
					ok
			end
	end.

%% Children.

new_child(State=#state{flow_control=FC, children=Children}, StreamID, Pid, IsFin) ->
    CFC = flow_control_new_with_defaults(FC),
	IsFin2 = if IsFin -> fin; true -> nofin end,
	State#state{last_streamid=StreamID,
		children=[#child{streamid=StreamID,
                         flow_control = CFC,
		pid=Pid, input=IsFin2}|Children]}.

get_child(StreamID, #state{children=Children}) ->
	lists:keyfind(StreamID, #child.streamid, Children).

replace_child(Child=#child{streamid=StreamID},
		State=#state{children=Children}) ->
	Children2 = lists:keyreplace(StreamID, #child.streamid, Children, Child),
	State#state{children=Children2}.

delete_child(Pid, State=#state{children=Children}) ->
	Children2 = lists:keydelete(Pid, #child.pid, Children),
	State#state{children=Children2}.

%% Request process.

-spec request_init(socket(), {inet:ip_address(), inet:port_number()},
		cowboy:onrequest_fun(), cowboy:onresponse_fun(),
		cowboy_middleware:env(), [module()],
		binary(), binary(), binary(), binary(), [{binary(), binary()}])
	-> ok.
request_init(FakeSocket, Peer, OnRequest, OnResponse,
		Env, Middlewares, Method, Host, Path, Version, Headers) ->
	{Host2, Port} = cow_http:parse_fullhost(Host),
	{Path2, Qs} = cow_http:parse_fullpath(Path),
	Version2 = cow_http:parse_version(Version),
	Req = cowboy_req:new(FakeSocket, ?MODULE, Peer,
		Method, Path2, Qs, Version2, Headers,
		Host2, Port, <<>>, true, false, OnResponse),
	case OnRequest of
		undefined ->
			execute(Req, Env, Middlewares);
		_ ->
			Req2 = OnRequest(Req),
			case cowboy_req:get(resp_state, Req2) of
				waiting -> execute(Req2, Env, Middlewares);
				_ -> ok
			end
	end.

-spec execute(cowboy_req:req(), cowboy_middleware:env(), [module()])
	-> ok.
execute(Req, _, []) ->
	cowboy_req:ensure_response(Req, 204);
execute(Req, Env, [Middleware|Tail]) ->
	case Middleware:execute(Req, Env) of
		{ok, Req2, Env2} ->
			execute(Req2, Env2, Tail);
		{suspend, Module, Function, Args} ->
			erlang:hibernate(?MODULE, resume,
				[Env, Tail, Module, Function, Args]);
		{halt, Req2} ->
			cowboy_req:ensure_response(Req2, 204);
		{error, Status, Req2} ->
			cowboy_req:maybe_reply(Status, Req2)
	end.

-spec resume(cowboy_middleware:env(), [module()],
	module(), module(), [any()]) -> ok.
resume(Env, Tail, Module, Function, Args) ->
	case apply(Module, Function, Args) of
		{ok, Req2, Env2} ->
			execute(Req2, Env2, Tail);
		{suspend, Module2, Function2, Args2} ->
			erlang:hibernate(?MODULE, resume,
				[Env, Tail, Module2, Function2, Args2]);
		{halt, Req2} ->
			cowboy_req:ensure_response(Req2, 204);
		{error, Status, Req2} ->
			cowboy_req:maybe_reply(Status, Req2)
	end.

%% Reply functions used by cowboy_req.

-spec reply(socket(), binary(), cowboy:http_headers(), iodata()) -> ok.
reply(Socket = {Pid, _}, Status, Headers, Body) ->
	_ = case iolist_size(Body) of
		0 -> Pid ! {reply, Socket, Status, Headers};
		_ -> Pid ! {reply, Socket, Status, Headers, Body}
	end,
	ok.


-spec push_reply(socket(), binary(), binary(), binary(), non_neg_integer(), cowboy:http_headers(), iodata()) ->
    {error, creashed} | {error, timeout, {ok, socket()}}.

push_reply(Socket = {Pid, _}, Method, Host, Path, Status, Headers, Body) ->
    %% Don't allow empty bodies... makes no sense here
    true = iolist_size(Body) > 0,

    MRef = monitor(process, Pid),
    Pid ! {push_reply, self(), Socket, Method, Host, Path, Status, Headers, Body},
    receive
        {'DOWN', Pid, _} ->
            {error, crashed};
        {stream_id, StreamId} ->
            demonitor(MRef),
            {ok, {Pid, StreamId}}
    after 5000 ->
            demonitor(MRef),
            {error, timeout}
    end.

-spec stream_reply(socket(), binary(), cowboy:http_headers()) -> ok.
stream_reply(Socket = {Pid, _}, Status, Headers) ->
	_ = Pid ! {stream_reply, Socket, Status, Headers},
	ok.

-spec stream_data(socket(), iodata()) -> ok.
stream_data(Socket = {Pid, _}, Data) ->
	_ = Pid ! {stream_data, Socket, Data},
	ok.

-spec stream_close(socket()) -> ok.
stream_close(Socket = {Pid, _}) ->
	_ = Pid ! {stream_close, Socket},
	ok.

%% Internal transport functions.

-spec name() -> spdy.
name() ->
	spdy.

-spec messages() -> {spdy, spdy_closed, spdy_error}.
messages() ->
	{spdy, spdy_closed, spdy_error}.

-spec recv(socket(), non_neg_integer(), timeout())
	-> {ok, binary()} | {error, timeout}.
recv(Socket = {Pid, _}, Length, Timeout) ->
	_ = Pid ! {recv, Socket, self(), Length, Timeout},
	receive
		{recv, Socket, Ret} ->
			Ret
	end.

-spec send(socket(), iodata()) -> ok.
send(Socket, Data) ->
	stream_data(Socket, Data).

%% We don't wait for the result of the actual sendfile call,
%% therefore we can't know how much was actually sent.
%% This isn't a problem as we don't use this value in Cowboy.
-spec sendfile(socket(), file:name_all()) -> {ok, undefined}.
sendfile(Socket = {Pid, _}, Filepath) ->
	_ = Pid ! {sendfile, Socket, Filepath},
	{ok, undefined}.

-spec setopts(inet:socket(), list()) -> ok.
setopts(Socket = {Pid, _}, [{active, once}]) ->
	_ = Pid ! {active, Socket, self()},
	ok;
setopts(Socket = {Pid, _}, [{active, false}]) ->
	_ = Pid ! {passive, Socket, self()},
	ok.
