module Products.Pagination
    exposing
        ( Data
        , default
        , toQueryString
        , fromQueryString
        , sortAndSetData
        )

import Paginate exposing (PaginatedList)
import RemoteData exposing (WebData)
import UrlParser as Url exposing ((<?>))
import Routing.Utils exposing (optionalIntParam)


type alias Data =
    { page : Int
    , perPage : Int
    }


default : Data
default =
    Data 1 25


toQueryString : Data -> String
toQueryString { page, perPage } =
    [ ( .page, page, "page" )
    , ( .perPage, perPage, "perPage" )
    ]
        |> List.map
            (\( selector, value, param ) ->
                ( selector default /= value
                , param ++ "=" ++ toString value
                )
            )
        |> List.filter Tuple.first
        |> List.map Tuple.second
        |> String.join "&"


fromQueryString :
    Url.Parser ((Data -> a) -> Int -> Int -> a) (Int -> Int -> b)
    -> Url.Parser (b -> a) a
fromQueryString pathParser =
    Url.map (\constructor page -> constructor << Data page)
        (pathParser
            <?> optionalIntParam "page" (default.page)
            <?> optionalIntParam "perPage" (default.perPage)
        )


sortAndSetData :
    Data
    -> (List a -> List a)
    -> (b -> PaginatedList a -> b)
    -> (b -> PaginatedList a)
    -> WebData b
    -> WebData b
sortAndSetData { page, perPage } sortFunction updateFunction selector data =
    let
        setPaginatedListConstraints =
            Paginate.changeItemsPerPage perPage
                >> Paginate.goTo page

        sortPaginatedList =
            Paginate.map sortFunction
    in
        RemoteData.map
            (\d ->
                selector d
                    |> setPaginatedListConstraints
                    |> sortPaginatedList
                    |> updateFunction d
            )
            data