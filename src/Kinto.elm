module Kinto exposing (..)

import Base64
import Http
import HttpBuilder
import Json.Decode as Decode exposing (field)
import Json.Encode as Encode
import String
import Task exposing (Task)


type alias Url =
    String


type alias Method =
    String



-- Auth


type alias Username =
    String


type alias Password =
    String


type alias Token =
    String


type Auth
    = NoAuth
    | Basic Username Password
    | Bearer Token



-- Kinto types


type alias BucketName =
    String


type alias CollectionName =
    String


type alias RecordId =
    String


type Endpoint
    = RootEndpoint
    | BucketListEndpoint
    | BucketEndpoint BucketName
    | CollectionListEndpoint BucketName
    | CollectionEndpoint BucketName CollectionName
    | RecordListEndpoint BucketName CollectionName
    | RecordEndpoint BucketName CollectionName RecordId


type alias Body =
    Encode.Value


type Request
    = KintoRequest Config Endpoint Method
    | KintoRequestWithBody Config Endpoint Method Body


type alias Config =
    { baseUrl : String
    , headers : List Http.Header
    , auth : Auth
    }


type alias ResourceConfig =
    { baseUrl : String
    , endpoint : Endpoint
    , headers : List ( String, String )
    }



-- Kinto errors


type alias ErrorRecord =
    { errno : Int
    , message : String
    , code : Int
    , error : String
    }


type alias StatusCode =
    Int


type alias StatusMsg =
    String


type Error
    = ServerError StatusCode StatusMsg String
    | KintoError StatusCode StatusMsg ErrorRecord
    | NetworkError Http.Error



-- Making requests


endpointUrl : String -> Endpoint -> Url
endpointUrl baseUrl endpoint =
    let
        url =
            if String.endsWith "/" baseUrl then
                String.dropRight 1 baseUrl
            else
                baseUrl

        joinUrl =
            String.join "/"
    in
        case endpoint of
            RootEndpoint ->
                -- Otherwise Kinto returns a 307
                -- See https://github.com/Kinto/kinto/issues/852
                url ++ "/"

            BucketListEndpoint ->
                joinUrl [ url, "buckets" ]

            BucketEndpoint bucketName ->
                joinUrl [ url, "buckets", bucketName ]

            CollectionListEndpoint bucketName ->
                joinUrl [ url, "buckets", bucketName, "collections" ]

            CollectionEndpoint bucketName collectionName ->
                joinUrl [ url, "buckets", bucketName, "collections", collectionName ]

            RecordListEndpoint bucketName collectionName ->
                joinUrl [ url, "buckets", bucketName, "collections", collectionName, "records" ]

            RecordEndpoint bucketName collectionName recordId ->
                joinUrl [ url, "buckets", bucketName, "collections", collectionName, "records", recordId ]


fromRequest : Request -> Http.Request Encode.Value
fromRequest request =
    let
        ( config, endpoint, method, body ) =
            case request of
                KintoRequest config endpoint method ->
                    ( config, endpoint, method, Http.emptyBody )

                KintoRequestWithBody config endpoint method body ->
                    ( config, endpoint, method, Http.jsonBody body )
    in
        Http.request
            { method = method
            , headers = headersFromConfig config
            , url = endpointUrl config.baseUrl endpoint
            , body = body
            , expect = Http.expectJson bodyDataDecoder
            , timeout = Nothing
            , withCredentials = False
            }


performQuery : (Result Error Decode.Value -> msg) -> Request -> Cmd msg
performQuery toMsg request =
    Http.send (toKintoResponse >> toMsg) (fromRequest request)


withHeader : String -> String -> Config -> Config
withHeader name value ({ headers } as config) =
    { config | headers = (Http.header name value) :: headers }


alwaysEncode : String -> String
alwaysEncode string =
    case Base64.encode string of
        Err msg ->
            Debug.crash "b64encoding failed" msg

        Ok hash ->
            hash


headersFromConfig : Config -> List Http.Header
headersFromConfig ({ auth, headers } as config) =
    case auth of
        NoAuth ->
            headers

        Basic username password ->
            config
                |> withHeader
                    "Authorization"
                    ("Basic " ++ (alwaysEncode (username ++ ":" ++ password)))
                |> .headers

        Bearer token ->
            config
                |> withHeader "Authorization" ("Bearer " ++ token)
                |> .headers


configure : Url -> Auth -> Config
configure baseUrl auth =
    Config baseUrl [] auth



-- Dealing with answers from the Kinto server


bodyDataDecoder : Decode.Decoder Decode.Value
bodyDataDecoder =
    (field "data" Decode.value)


errorDecoder : Decode.Decoder ErrorRecord
errorDecoder =
    Decode.map4 ErrorRecord
        (field "errno" Decode.int)
        (field "message" Decode.string)
        (field "code" Decode.int)
        (field "error" Decode.string)


toKintoResponse : Result Http.Error a -> Result Error a
toKintoResponse response =
    response
        |> Result.mapError extractError


extractError : Http.Error -> Error
extractError error =
    case error of
        Http.BadStatus { status, body } ->
            extractKintoError status.code status.message body

        Http.BadPayload str { status, body } ->
            ServerError
                status.code
                status.message
                ("failed decoding json: "
                    ++ str
                    ++ "\n\nBody received from server: "
                    ++ body
                )

        anyError ->
            NetworkError anyError


extractKintoError : StatusCode -> StatusMsg -> String -> Error
extractKintoError statusCode statusMsg body =
    case Decode.decodeString errorDecoder body of
        Ok errRecord ->
            KintoError statusCode statusMsg errRecord

        Err err ->
            ServerError statusCode statusMsg err



-- High level API
-- GET


getBucketList : (Result Error Decode.Value -> msg) -> Config -> Cmd msg
getBucketList toMsg config =
    performQuery toMsg (KintoRequest config BucketListEndpoint "GET")


getBucket : (Result Error Decode.Value -> msg) -> Config -> BucketName -> Cmd msg
getBucket toMsg config bucket =
    performQuery toMsg (KintoRequest config (BucketEndpoint bucket) "GET")


getCollectionList :
    (Result Error Decode.Value -> msg)
    -> Config
    -> BucketName
    -> Cmd msg
getCollectionList toMsg config bucket =
    performQuery toMsg (KintoRequest config (CollectionListEndpoint bucket) "GET")


getCollection :
    (Result Error Decode.Value -> msg)
    -> Config
    -> BucketName
    -> CollectionName
    -> Cmd msg
getCollection toMsg config bucket collection =
    performQuery toMsg (KintoRequest config (CollectionEndpoint bucket collection) "GET")


getRecordList :
    (Result Error Decode.Value -> msg)
    -> Config
    -> BucketName
    -> CollectionName
    -> Cmd msg
getRecordList toMsg config bucket collection =
    performQuery toMsg (KintoRequest config (RecordListEndpoint bucket collection) "GET")


getRecord :
    (Result Error Decode.Value -> msg)
    -> Config
    -> BucketName
    -> CollectionName
    -> RecordId
    -> Cmd msg
getRecord toMsg config bucket collection recordId =
    performQuery
        toMsg
        (KintoRequest
            config
            (RecordEndpoint bucket collection recordId)
            "GET"
        )



-- CREATE


createBucket : (Result Error Decode.Value -> msg) -> Config -> Body -> Cmd msg
createBucket toMsg config body =
    performQuery
        toMsg
        (KintoRequestWithBody
            config
            BucketListEndpoint
            "POST"
            body
        )


createCollection :
    (Result Error Decode.Value -> msg)
    -> Config
    -> BucketName
    -> Body
    -> Cmd msg
createCollection toMsg config bucket body =
    performQuery
        toMsg
        (KintoRequestWithBody
            config
            (CollectionListEndpoint bucket)
            "POST"
            body
        )


createRecord :
    (Result Error Decode.Value -> msg)
    -> Config
    -> BucketName
    -> CollectionName
    -> Body
    -> Cmd msg
createRecord toMsg config bucket collection body =
    performQuery
        toMsg
        (KintoRequestWithBody
            config
            (RecordListEndpoint bucket collection)
            "POST"
            body
        )



-- UPDATE


updateBucket : (Result Error Decode.Value -> msg) -> Config -> BucketName -> Body -> Cmd msg
updateBucket toMsg config bucket body =
    performQuery
        toMsg
        (KintoRequestWithBody
            config
            (BucketEndpoint bucket)
            "PATCH"
            body
        )


updateCollection :
    (Result Error Decode.Value -> msg)
    -> Config
    -> BucketName
    -> CollectionName
    -> Body
    -> Cmd msg
updateCollection toMsg config bucket collection body =
    performQuery
        toMsg
        (KintoRequestWithBody
            config
            (CollectionEndpoint bucket collection)
            "PATCH"
            body
        )


updateRecord :
    (Result Error Decode.Value -> msg)
    -> Config
    -> BucketName
    -> CollectionName
    -> RecordId
    -> Body
    -> Cmd msg
updateRecord toMsg config bucket collection recordId body =
    performQuery
        toMsg
        (KintoRequestWithBody
            config
            (RecordEndpoint bucket collection recordId)
            "PATCH"
            body
        )



-- REPLACE


replaceBucket : (Result Error Decode.Value -> msg) -> Config -> BucketName -> Body -> Cmd msg
replaceBucket toMsg config bucket body =
    performQuery
        toMsg
        (KintoRequestWithBody
            config
            (BucketEndpoint bucket)
            "PUT"
            body
        )


replaceCollection :
    (Result Error Decode.Value -> msg)
    -> Config
    -> BucketName
    -> CollectionName
    -> Body
    -> Cmd msg
replaceCollection toMsg config bucket collection body =
    performQuery
        toMsg
        (KintoRequestWithBody
            config
            (CollectionEndpoint bucket collection)
            "PUT"
            body
        )


replaceRecord :
    (Result Error Decode.Value -> msg)
    -> Config
    -> BucketName
    -> CollectionName
    -> RecordId
    -> Body
    -> Cmd msg
replaceRecord toMsg config bucket collection recordId body =
    performQuery
        toMsg
        (KintoRequestWithBody
            config
            (RecordEndpoint bucket collection recordId)
            "PUT"
            body
        )



-- DELETE


deleteBucket : (Result Error Decode.Value -> msg) -> Config -> BucketName -> Cmd msg
deleteBucket toMsg config bucket =
    performQuery
        toMsg
        (KintoRequest
            config
            (BucketEndpoint bucket)
            "DELETE"
        )


deleteCollection :
    (Result Error Decode.Value -> msg)
    -> Config
    -> BucketName
    -> CollectionName
    -> Cmd msg
deleteCollection toMsg config bucket collection =
    performQuery
        toMsg
        (KintoRequest
            config
            (CollectionEndpoint bucket collection)
            "DELETE"
        )


deleteRecord :
    (Result Error Decode.Value -> msg)
    -> Config
    -> BucketName
    -> CollectionName
    -> RecordId
    -> Cmd msg
deleteRecord toMsg config bucket collection recordId =
    performQuery
        toMsg
        (KintoRequest
            config
            (RecordEndpoint bucket collection recordId)
            "DELETE"
        )



-- New API experiment


send : (Result Error a -> msg) -> HttpBuilder.RequestBuilder a -> Cmd msg
send tagger builder =
    builder
        |> HttpBuilder.send (toKintoResponse >> tagger)


get : ResourceConfig -> HttpBuilder.RequestBuilder Decode.Value
get config =
    endpointUrl config.baseUrl config.endpoint
        |> HttpBuilder.get
        |> HttpBuilder.withHeaders config.headers
        |> HttpBuilder.withExpect (Http.expectJson Decode.value)


delete : ResourceConfig -> HttpBuilder.RequestBuilder Decode.Value
delete config =
    endpointUrl config.baseUrl config.endpoint
        |> HttpBuilder.delete
        |> HttpBuilder.withHeaders config.headers
        |> HttpBuilder.withExpect (Http.expectJson Decode.value)


create : Body -> ResourceConfig -> HttpBuilder.RequestBuilder Decode.Value
create body config =
    endpointUrl config.baseUrl config.endpoint
        |> HttpBuilder.post
        |> HttpBuilder.withHeaders config.headers
        |> HttpBuilder.withJsonBody body
        |> HttpBuilder.withExpect (Http.expectJson Decode.value)


update : Body -> ResourceConfig -> HttpBuilder.RequestBuilder Decode.Value
update body config =
    endpointUrl config.baseUrl config.endpoint
        |> HttpBuilder.patch
        |> HttpBuilder.withHeaders config.headers
        |> HttpBuilder.withJsonBody body
        |> HttpBuilder.withExpect (Http.expectJson Decode.value)


withDecoder :
    Decode.Decoder a
    -> HttpBuilder.RequestBuilder b
    -> HttpBuilder.RequestBuilder a
withDecoder decoder builder =
    builder
        |> HttpBuilder.withExpect (Http.expectJson decoder)


authFromConfig : Auth -> ( String, String )
authFromConfig auth =
    case auth of
        NoAuth ->
            ( "", "" )

        Basic username password ->
            ( "Authorization"
            , ("Basic " ++ (alwaysEncode (username ++ ":" ++ password)))
            )

        Bearer token ->
            ( "Authorization", ("Bearer " ++ token) )


configureResource :
    Url
    -> Endpoint
    -> Auth
    -> ResourceConfig
configureResource baseUrl endpoint auth =
    ResourceConfig baseUrl endpoint [ (authFromConfig auth) ]
