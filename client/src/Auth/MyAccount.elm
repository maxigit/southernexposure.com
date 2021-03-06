module Auth.MyAccount exposing (getDetails, view)

import Api
import Html exposing (..)
import Html.Attributes exposing (class)
import Html.Events exposing (onClick)
import Locations exposing (AddressLocations)
import Messages exposing (Msg(..))
import Models.Fields exposing (Cents(..))
import PageData exposing (MyAccount)
import Routing exposing (Route(..))
import Time
import Views.Format as Format
import Views.Utils exposing (routeLinkAttributes)


getDetails : Maybe Int -> Cmd Msg
getDetails maybeLimit =
    Api.get (Api.CustomerMyAccount maybeLimit)
        |> Api.withJsonResponse PageData.myAccountDecoder
        |> Api.sendRequest GetMyAccountDetails


view : Time.Zone -> AddressLocations -> MyAccount -> List (Html Msg)
view zone locations { storeCredit, orderSummaries } =
    let
        accountLinks =
            [ li []
                [ a (routeLinkAttributes EditLogin)
                    [ text "Edit Login Details" ]
                ]
            , li []
                [ a (routeLinkAttributes EditAddress)
                    [ text "Edit Billing & Shipping Addresses" ]
                ]
            ]

        (Cents credit) =
            storeCredit

        storeCreditText =
            if credit > 0 then
                p []
                    [ text "You have "
                    , b [] [ text <| Format.cents storeCredit ]
                    , text <|
                        " of Store Credit available. You can use this during "
                            ++ "Checkout."
                    ]

            else
                text ""

        summaryTable =
            if List.isEmpty orderSummaries then
                text ""

            else
                div []
                    [ h3 [] [ text "Recent Orders" ]
                    , orderTable zone locations orderSummaries
                    ]
    in
    [ h1 [] [ text "My Account" ]
    , hr [] []
    , if credit > 0 then
        div [ class "row" ]
            [ div [ class "col-sm-6" ] [ ul [] accountLinks ]
            , div [ class "col-sm-6" ] [ storeCreditText ]
            ]

      else
        ul [] accountLinks
    , summaryTable
    ]


orderTable : Time.Zone -> AddressLocations -> List PageData.OrderSummary -> Html Msg
orderTable zone locations orderSummaries =
    let
        orderRow { id, shippingAddress, status, total, created } =
            tr []
                [ td [ class "text-center" ] [ text <| Format.date zone created ]
                , td [ class "text-center" ] [ text <| String.fromInt id ]
                , td [] [ addressInfo shippingAddress ]
                , td [ class "text-center" ] [ text <| PageData.statusText status ]
                , td [ class "text-right" ] [ text <| Format.cents total ]
                , td [ class "text-center" ]
                    [ a
                        (class "btn btn-light btn-sm"
                            :: routeLinkAttributes (OrderDetails id)
                        )
                        [ text "View" ]
                    ]
                ]

        orderBlock { id, shippingAddress, status, total, created } =
            div []
                [ h4 [ class "d-flex" ]
                    [ text <| "Order #" ++ String.fromInt id
                    , small [ class "ml-auto" ] [ text <| Format.date zone created ]
                    ]
                , h5 [ class "mb-1" ] [ text "Ship To:" ]
                , addressInfo shippingAddress
                , div [ class "d-flex font-weight-bold mb-1" ]
                    [ div [] [ text <| PageData.statusText status ]
                    , div [ class "ml-auto" ] [ text <| Format.cents total ]
                    ]
                , a (class "mb-1 btn btn-light btn-block" :: routeLinkAttributes (OrderDetails id))
                    [ text "View Order Details" ]
                ]

        showAllButton =
            div [ class "form-group text-right" ]
                [ button [ class "btn btn-light", onClick ShowAllOrders ]
                    [ text "Show All Orders" ]
                ]

        addressInfo { firstName, lastName, street, city, state, zipCode } =
            address [ class "mb-0" ]
                [ b [] [ text <| firstName ++ " " ++ lastName ]
                , br [] []
                , text street
                , br [] []
                , text city
                , text ", "
                , state
                    |> Maybe.andThen (Locations.regionName locations)
                    |> Maybe.map text
                    |> Maybe.withDefault (text "")
                , text " "
                , text zipCode
                ]
    in
    div []
        [ table [ class "d-none d-md-table table table-sm table-striped" ]
            [ thead []
                [ tr []
                    [ th [ class "text-center" ] [ text "Date" ]
                    , th [ class "text-center" ] [ text "Order #" ]
                    , th [] [ text "Shipping Address" ]
                    , th [ class "text-center" ] [ text "Order Status" ]
                    , th [ class "text-right" ] [ text "Total" ]
                    , th [] []
                    ]
                ]
            , tbody [] <| List.map orderRow orderSummaries
            ]
        , div [ class "account-order-blocks mb-3 d-md-none" ] <|
            List.map orderBlock orderSummaries
        , showAllButton
        ]
