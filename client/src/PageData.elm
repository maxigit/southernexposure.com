module PageData
    exposing
        ( PageData
        , initial
        , PredecessorCategory
        , CategoryDetails
        , categoryDetailsDecoder
        , categoryConfig
        , ProductDetails
        , productDetailsDecoder
        , SearchResults
        , searchConfig
        , ProductData
        , productDataDecoder
        , AdvancedSearch
        , advancedSearchDecoder
        , Location
        , LocationData
        , locationDataDecoder
        , Region(..)
        , regionEncoder
        , regionDecoder
        , ContactDetails
        , contactDetailsDecoder
        , contactDetailsEncoder
        , CartItemId(..)
        , CartItem
        , CartDetails
        , cartDetailsDecoder
        )

import Dict exposing (Dict)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Paginate exposing (Paginated)
import RemoteData exposing (WebData)
import Api
import Category exposing (Category, CategoryId(..))
import StaticPage exposing (StaticPage)
import Product exposing (Product, ProductVariant, ProductVariantId(..))
import Products.Pagination as Pagination
import Products.Sorting as Sorting
import Search
import SeedAttribute exposing (SeedAttribute)


-- MODEL


type alias PageData =
    { categoryDetails : Paginated ProductData { slug : String, sorting : Sorting.Option } CategoryDetails
    , productDetails : WebData ProductDetails
    , advancedSearch : WebData AdvancedSearch
    , searchResults : Paginated ProductData { data : Search.Data, sorting : Sorting.Option } String
    , pageDetails : WebData StaticPage
    , locations : WebData LocationData
    , contactDetails : WebData ContactDetails
    , cartDetails : WebData CartDetails
    }


initial : PageData
initial =
    let
        categoryPaginate =
            Paginate.initial categoryConfig
                { slug = "", sorting = Sorting.default }
                (.page Pagination.default)
                (.perPage Pagination.default)
                |> Tuple.first

        searchPaginate =
            Paginate.initial searchConfig
                { data = Search.initial, sorting = Sorting.default }
                (.page Pagination.default)
                (.perPage Pagination.default)
                |> Tuple.first
    in
        { categoryDetails = categoryPaginate
        , productDetails = RemoteData.NotAsked
        , advancedSearch = RemoteData.NotAsked
        , searchResults = searchPaginate
        , pageDetails = RemoteData.NotAsked
        , locations = RemoteData.NotAsked
        , contactDetails = RemoteData.NotAsked
        , cartDetails = RemoteData.NotAsked
        }



-- Category Details


type alias CategoryDetails =
    { category : Category
    , subCategories : List Category
    , predecessors : List PredecessorCategory
    }


categoryDetailsDecoder : Decoder CategoryDetails
categoryDetailsDecoder =
    Decode.map3 CategoryDetails
        (Decode.field "category" Category.decoder)
        (Decode.field "subCategories" <| Decode.list Category.decoder)
        (Decode.field "predecessors" <|
            Decode.map List.reverse <|
                Decode.list predecessorCategoryDecoder
        )


categoryConfig : Paginate.Config ProductData { slug : String, sorting : Sorting.Option } CategoryDetails
categoryConfig =
    let
        request { slug, sorting } page perPage =
            Api.get (Api.CategoryDetails slug <| Pagination.Data page perPage sorting)
                |> Api.withJsonResponse fetchDecoder
                |> Api.toRequest

        fetchDecoder =
            Decode.map3 Paginate.FetchResponse
                (Decode.field "products" <| Decode.list productDataDecoder)
                (Decode.field "total" Decode.int)
                (Decode.map Just categoryDetailsDecoder)
    in
        Paginate.makeConfig request



-- Product Details


type alias ProductDetails =
    { product : Product
    , variants : Dict Int ProductVariant
    , maybeSeedAttribute : Maybe SeedAttribute
    , categories : List Category
    , predecessors : List PredecessorCategory
    }


productDetailsDecoder : Decoder ProductDetails
productDetailsDecoder =
    Decode.map5 ProductDetails
        (Decode.field "product" Product.decoder)
        (Decode.field "variants" variantDictDecoder)
        (Decode.field "seedAttribute" <| Decode.nullable SeedAttribute.decoder)
        (Decode.field "categories" <| Decode.list Category.decoder)
        (Decode.field "predecessors" <|
            Decode.map List.reverse <|
                Decode.list predecessorCategoryDecoder
        )



-- Search Results


type alias SearchResults =
    Paginated ProductData { data : Search.Data, sorting : Sorting.Option } String


searchConfig : Paginate.Config ProductData { data : Search.Data, sorting : Sorting.Option } String
searchConfig =
    let
        fetchDecoder =
            Decode.map3 Paginate.FetchResponse
                (Decode.field "products" <| Decode.list productDataDecoder)
                (Decode.field "total" Decode.int)
                (Decode.field "categoryName" <| Decode.nullable Decode.string)

        request { data, sorting } page perPage =
            Api.post (Api.ProductSearch <| Pagination.Data page perPage sorting)
                |> Api.withJsonBody (Search.encode data)
                |> Api.withJsonResponse fetchDecoder
                |> Api.toRequest
    in
        Paginate.makeConfig request



-- Locations


type alias Location =
    { code : String
    , name : String
    }


locationDecoder : Decoder Location
locationDecoder =
    Decode.map2 Location
        (Decode.field "code" Decode.string)
        (Decode.field "name" Decode.string)


type alias LocationData =
    { countries : List Location
    , states : List Location
    , armedForces : List Location
    , provinces : List Location
    }


locationDataDecoder : Decoder LocationData
locationDataDecoder =
    Decode.map4 LocationData
        (Decode.field "countries" <| Decode.list locationDecoder)
        (Decode.field "states" <| Decode.list locationDecoder)
        (Decode.field "armedForces" <| Decode.list locationDecoder)
        (Decode.field "provinces" <| Decode.list locationDecoder)



-- Contact Details


type Region
    = USState String
    | ArmedForces String
    | CAProvince String
    | Custom String


regionDecoder : Decoder Region
regionDecoder =
    [ ( USState, "state" )
    , ( ArmedForces, "armedForces" )
    , ( CAProvince, "province" )
    , ( Custom, "custom" )
    ]
        |> List.map
            (\( constructor, field ) ->
                Decode.map constructor (Decode.field field Decode.string)
            )
        |> Decode.oneOf


regionEncoder : Region -> Value
regionEncoder region =
    let
        regionObject key value =
            Encode.object [ ( key, Encode.string value ) ]
    in
        case region of
            USState code ->
                regionObject "state" code

            ArmedForces code ->
                regionObject "armedForces" code

            CAProvince code ->
                regionObject "province" code

            Custom str ->
                regionObject "custom" str


type alias ContactDetails =
    { firstName : String
    , lastName : String
    , street : String
    , addressTwo : String
    , city : String
    , state : Region
    , zipCode : String
    , country : String
    , phoneNumber : String
    }


contactDetailsDecoder : Decoder ContactDetails
contactDetailsDecoder =
    Decode.map8 ContactDetails
        (Decode.field "firstName" Decode.string)
        (Decode.field "lastName" Decode.string)
        (Decode.field "addressOne" Decode.string)
        (Decode.field "addressTwo" Decode.string)
        (Decode.field "city" Decode.string)
        (Decode.field "state" regionDecoder)
        (Decode.field "zipCode" Decode.string)
        (Decode.field "country" Decode.string)
        |> Decode.andThen
            (\constr ->
                Decode.map constr
                    (Decode.field "telephone" Decode.string)
            )


contactDetailsEncoder : ContactDetails -> Value
contactDetailsEncoder details =
    [ ( "firstName", details.firstName )
    , ( "lastName", details.lastName )
    , ( "addressOne", details.street )
    , ( "addressTwo", details.addressTwo )
    , ( "city", details.city )
    , ( "zipCode", details.zipCode )
    , ( "country", details.country )
    , ( "telephone", details.phoneNumber )
    ]
        |> List.map (Tuple.mapSecond Encode.string)
        |> ((::) <| ( "state", regionEncoder details.state ))
        |> Encode.object



-- Carts


type CartItemId
    = CartItemId Int


type alias CartItem =
    { id : CartItemId
    , product : Product
    , variant : ProductVariant
    , maybeSeedAttribute : Maybe SeedAttribute
    , quantity : Int
    }


cartItemDecoder : Decoder CartItem
cartItemDecoder =
    Decode.map5 CartItem
        (Decode.field "id" <| Decode.map CartItemId Decode.int)
        (Decode.field "product" Product.decoder)
        (Decode.field "variant" Product.variantDecoder)
        (Decode.field "seedAttribute" <| Decode.nullable SeedAttribute.decoder)
        (Decode.field "quantity" Decode.int)


type alias CartDetails =
    { items : List CartItem
    }


cartDetailsDecoder : Decoder CartDetails
cartDetailsDecoder =
    Decode.map CartDetails
        (Decode.field "items" <| Decode.list cartItemDecoder)



-- Common Page Data


type alias PredecessorCategory =
    { id : CategoryId
    , slug : String
    , name : String
    }


predecessorCategoryDecoder : Decoder PredecessorCategory
predecessorCategoryDecoder =
    Decode.map3 PredecessorCategory
        (Decode.field "id" <| Decode.map CategoryId Decode.int)
        (Decode.field "slug" Decode.string)
        (Decode.field "name" Decode.string)


type alias ProductData =
    ( Product, Dict Int ProductVariant, Maybe SeedAttribute )


productDataDecoder : Decoder ProductData
productDataDecoder =
    Decode.map3 (,,)
        (Decode.field "product" Product.decoder)
        (Decode.field "variants" variantDictDecoder)
        (Decode.field "seedAttribute" <| Decode.nullable SeedAttribute.decoder)


variantDictDecoder : Decoder (Dict Int ProductVariant)
variantDictDecoder =
    Decode.list Product.variantDecoder
        |> Decode.map
            (List.foldl
                (\v -> Dict.insert ((\(ProductVariantId i) -> i) v.id) v)
                Dict.empty
            )


type alias AdvancedSearch =
    List AdvancedSearchCategory


type alias AdvancedSearchCategory =
    { id : CategoryId
    , name : String
    }


advancedSearchDecoder : Decoder AdvancedSearch
advancedSearchDecoder =
    Decode.field "categories" <|
        Decode.list <|
            Decode.map2 AdvancedSearchCategory
                (Decode.field "id" <| Decode.map CategoryId Decode.int)
                (Decode.field "name" Decode.string)
