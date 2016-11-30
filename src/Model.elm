module Model exposing (..)

import Task
import Time exposing (Time, second)
import HttpBuilder exposing (withJsonBody, withHeader, withExpect)
import Json.Decode as Decode exposing (Decoder, string, at, list, map4, field, maybe, int, Value, decodeValue)
import Json.Encode as Encode
import Form
import Dict
import Http
import Kinto


-- TODO:
-- - Expose only what's necessary
-- MODEL and TYPES


type alias RecordId =
    String


type alias Record =
    { id : RecordId
    , title : Maybe String
    , description : Maybe String
    , last_modified : Int
    }


type alias Records =
    Dict.Dict RecordId Record


type alias Model =
    { error : Maybe String
    , records : Records
    , formData : Form.Model
    , currentTime : Time
    }


type Msg
    = NoOp
    | Tick Time
    | FetchRecordResponse (Result Kinto.Error Record)
    | FetchRecords
    | FetchRecordsResponse (Result Kinto.Error (List Record))
    | FormMsg Form.Msg
    | CreateRecordResponse (Result Kinto.Error Record)
    | EditRecord RecordId
    | EditRecordResponse (Result Kinto.Error Record)
    | DeleteRecord RecordId
    | DeleteRecordResponse (Result Kinto.Error Record)


init : ( Model, Cmd Msg )
init =
    ( initialModel
    , Cmd.batch [ fetchRecordList ]
    )


initialModel : Model
initialModel =
    { error = Nothing
    , records = Dict.empty
    , formData = Form.init
    , currentTime = 0
    }



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        NoOp ->
            ( model, Cmd.none )

        Tick newTime ->
            ( { model | currentTime = newTime }, Cmd.none )

        FetchRecords ->
            ( { model | records = Dict.empty, error = Nothing }, fetchRecordList )

        FetchRecordResponse response ->
            case response of
                Ok record ->
                    ( { model
                        | formData = recordToFormData record
                        , error = Nothing
                      }
                    , Cmd.none
                    )

                Err error ->
                    ( { model | error = Just <| toString error }, Cmd.none )

        FetchRecordsResponse response ->
            case response of
                Ok recordList ->
                    let
                        recordsToDict records =
                            List.map (\r -> ( r.id, r )) records
                                |> Dict.fromList
                    in
                        ( { model
                            | records = recordsToDict recordList
                            , error = Nothing
                          }
                        , Cmd.none
                        )

                Err error ->
                    ( { model | error = Just <| toString error }, Cmd.none )

        FormMsg subMsg ->
            let
                ( updated, formMsg ) =
                    Form.update subMsg model.formData
            in
                case formMsg of
                    Nothing ->
                        ( { model
                            | formData = updated
                            , records = updateRecordInList updated model.records
                          }
                        , Cmd.none
                        )

                    Just (Form.FormSubmitted data) ->
                        ( { model | formData = updated }, sendFormData model data )

        CreateRecordResponse response ->
            case response of
                Ok _ ->
                    ( { model | formData = Form.init }, fetchRecordList )

                Err error ->
                    ( { model | error = Just <| toString error }, Cmd.none )

        EditRecord recordId ->
            ( model, fetchRecord recordId )

        EditRecordResponse response ->
            case response of
                Ok _ ->
                    ( model, fetchRecordList )

                Err err ->
                    ( { model | error = Just <| toString err }, Cmd.none )

        DeleteRecord recordId ->
            ( model, deleteRecord recordId )

        DeleteRecordResponse response ->
            case response of
                Ok record ->
                    ( { model
                        | records = removeRecordFromList record model.records
                        , error = Nothing
                      }
                    , fetchRecordList
                    )

                Err err ->
                    ( { model | error = Just <| toString err }, Cmd.none )



-- Subscriptions


subscriptions : Model -> Sub Msg
subscriptions model =
    Time.every second Tick



-- Helpers


recordToFormData : Record -> Form.Model
recordToFormData { id, title, description } =
    Form.Model
        (Just id)
        (Maybe.withDefault "" title)
        (Maybe.withDefault "" description)


encodeFormData : Form.Model -> Encode.Value
encodeFormData { title, description } =
    Encode.object
        [ ( "data"
          , Encode.object
                [ ( "title", Encode.string title )
                , ( "description", Encode.string description )
                ]
          )
        ]


removeRecordFromList : Record -> Records -> Records
removeRecordFromList { id } records =
    Dict.remove id records


updateRecordInList : Form.Model -> Records -> Records
updateRecordInList formData records =
    -- This enables live reflecting ongoing form updates in the records list
    case formData.id of
        Nothing ->
            records

        Just id ->
            Dict.update id (updateRecord formData) records


updateRecord : Form.Model -> Maybe Record -> Maybe Record
updateRecord formData record =
    case record of
        Nothing ->
            record

        Just record ->
            Just
                { record
                    | title = Just formData.title
                    , description = Just formData.description
                }



-- Kinto client configuration


client : Kinto.Client
client =
    Kinto.client
        "https://kinto.dev.mozaws.net/v1/"
        (Kinto.Basic "test" "test")


recordResource : Kinto.Resource Record
recordResource =
    Kinto.recordResource "default" "test-items" decodeRecord


decodeRecord : Decoder Record
decodeRecord =
    (map4 Record
        (field "id" string)
        (maybe (field "title" string))
        (maybe (field "description" string))
        (field "last_modified" int)
    )



-- Kinto API calls


fetchRecord : RecordId -> Cmd Msg
fetchRecord recordId =
    client
        |> Kinto.get recordResource recordId
        |> Kinto.send FetchRecordResponse


fetchRecordList : Cmd Msg
fetchRecordList =
    client
        |> Kinto.getList recordResource
        |> Kinto.sortBy [ "title", "description" ]
        |> Kinto.send FetchRecordsResponse


deleteRecord : RecordId -> Cmd Msg
deleteRecord recordId =
    client
        |> Kinto.delete recordResource recordId
        |> Kinto.send DeleteRecordResponse


sendFormData : Model -> Form.Model -> Cmd Msg
sendFormData model formData =
    let
        data =
            encodeFormData formData
    in
        case formData.id of
            Nothing ->
                client
                    |> Kinto.create recordResource data
                    |> Kinto.send CreateRecordResponse

            Just recordId ->
                client
                    |> Kinto.update recordResource recordId data
                    |> Kinto.send EditRecordResponse
