%%% -*- erlang -*-
%%%
%%% This file is part of coffer released under the Apache license 2.
%%% See the NOTICE for more information.
%%%
-module(coffer_client).

-record(client_ctx, {url,
                     pool,
                     opts}).

%% API to connect to a storage
-export([open/1, open/2,
         close/1,
         is_exists/2,
         fetch/2,
         upload/1]).

%% i/o api
-export([reader_fun/1,
         upload_fun/2,
         process/1, process/2]).

%% client uril
-export([start/0, stop/0]).

-define(LIMIT, 16#10000000).

%% CLIENT API

%% @doc open a connection to a storage, the url given is the Url of a storage.
%% A client is dedicated to a storage and has its own pool.
open(Url) ->
    open(Url, []).

%% @doc same as above but with connections options. See the hackney
%% options for it. A special pool_opts property has been added to create
%% the client pool and pass needed options to it.
open(Url, Opts) ->
    %% each client maintain its own pool
    PoolName = list_to_atom(binary_to_list(Url)),
    PoolOpts = proplists:get_value(pool_opts, Opts, [{pool_size, 10}]),
    {ok, Pool} = hackney:start_pool(PoolName, PoolOpts),
    %% set client opts
    CtxOpts = [{pool, Pool} | Opts],
    %% return the client context
    #client_ctx{url=Url,
                pool = Pool,
                opts = CtxOpts}.

%% @doc close a connection to a storage and stop the pool
close(#client_ctx{pool=Pool}) ->
    hackney:stop_pool(Pool).

%% @doc test if a blob is already available on the storage
is_exists(#client_ctx{opts=Opts}=Ctx, BlobRef) ->
    case hackney:head(blob_url(Ctx, BlobRef), [], <<>>, Opts) of
        {ok, 200, _, Ctx1} ->
            hackney:skip_body(Ctx1),
            true;
        {ok, 404, _, Ctx1} ->
            hackney:skip_body(Ctx1),
            false;
        Error ->
            Error
    end.

%% @doc fetch a blob from the storage
fetch(#client_ctx{opts=Opts}=Ctx, BlobRef) ->
    Resp = hackney:get(blob_url(Ctx, BlobRef), [], <<>>, Opts),
    case process_response(Resp) of
        {ok, 200, _Hdr, Ctx1} ->
            ReaderFun = fun ?MODULE:reader_fun/1,
            {ok, {ReaderFun, Ctx1}};
        {ok, _, _, _} ->
            {error, {uknown_resp, Resp}};
        {error, _} = Error ->
            Error
    end.

%% @doc upload a blob to the storage
upload(#client_ctx{url=Url, opts=Opts}) ->
    case hackney:post(Url, [], stream_multipart, Opts) of
        {ok, Ctx1} ->
            WriterFun = fun ?MODULE:upload_fun/2,
            {ok, {WriterFun, Ctx1}};
        Error ->
            Error
    end.


%% I/O functions

%% process read fun
process({Fun, State}) ->
    Fun(State).

%% process write fun
process({Fun, State}, Msg) ->
    Fun(State, Msg).

%% reeade function used to fetch a body from a storage
reader_fun(Ctx) ->
    case hackney:stream_body(Ctx) of
        {ok, Data, Ctx2} ->
            {ok, Data, Ctx2};
        {done, _Ctx2} ->
            eob;
        {error, Reason} ->
            {error, Reason}
    end.

%% upload function used to send a blob to a storge using the multipart
%% api.
upload_fun(Ctx, done) ->
    Resp = hackney_multipart:stream(eof, Ctx),
    case process_response(Resp) of
        {ok, 201, _, Ctx} ->
            case hackney:body(Ctx) of
                {ok, Body, _} ->
                    Decoded = jsx:decode(Body),
                    {ok, Decoded};
                Error ->
                    Error
            end;
        {ok, _, _, _} ->
            {error, {uknown_resp, Resp}};
        Error ->
            Error
    end;

upload_fun(Ctx, {start, BlobRef}) ->
    hackney_multipart:stream({data, {start, BlobRef, BlobRef,
                                     <<"application/octet-stream">>}},
                             Ctx);

upload_fun(Ctx, eob) ->
    hackney_multipart:stream({data, eof}, Ctx);

upload_fun(Ctx, Bin) when is_binary(Bin) ->
    hackney_multipart:stream({data, Bin}, Ctx).

%%% CLIENT URIL

%% @doc Start the coffer_client application. Useful when testing using the shell.
start() ->
    hackney_deps:ensure(),
    application:load(coffer_application),
    coffer_util:ensure_deps_started(coffer_client),
    application:start(coffer_client).

%% @doc Stop the coffer_client application. Useful when testing using the shell.
stop() ->
    application:stop(coffer_client).


%% @private
%%
%%

%% make the blob url
blob_url(Ctx, {HashType, Hash}) ->
    HashType1 = coffer_util:to_binary(HashType),
    Hash1 = coffer_util:to_binary(Hash),
    blob_url(Ctx, << HashType1/binary, "-", Hash1/binary >>);
blob_url(Ctx, BlobRef) when is_list(BlobRef) ->
    blob_url(Ctx, list_to_binary(BlobRef));
blob_url(#client_ctx{url=Url}, BlobRef) ->
    << Url/binary, "/", BlobRef/binary >>.

%% process the response and skip the body on usual suspect
process_response({ok, 404, _Hdrs, Ctx}) ->
    hackney:skip_body(Ctx),
    {error, not_found};
process_response({ok, 409, _Hdrs, Ctx}) ->
    hackney:skip_body(Ctx),
    {error, already_exists};
process_response({ok, Status, _Hdrs, _Ctx}=Resp) ->
    case lists:member(Status, [200, 201, 202]) of
        true ->
            Resp;
        false ->
            {error, Resp}
    end;
process_response(Error) ->
    Error.
