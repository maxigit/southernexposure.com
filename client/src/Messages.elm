module Messages exposing (Msg(..))

import Paginate
import RemoteData exposing (WebData)
import AdvancedSearch
import Auth.CreateAccount as CreateAccount
import Auth.Login as Login
import Auth.EditLogin as EditLogin
import Auth.EditContact as EditContact
import StaticPage exposing (StaticPage)
import PageData exposing (ProductData)
import Routing exposing (Route)
import SiteUI exposing (NavigationData)
import SiteUI.Search as SiteSearch
import User


type Msg
    = UrlUpdate Route
    | NavigateTo Route
    | LogOut
    | OtherTabLoggedIn { userId : Int, token : String }
    | SearchMsg SiteSearch.Msg
    | AdvancedSearchMsg AdvancedSearch.Msg
    | CreateAccountMsg CreateAccount.Msg
    | LoginMsg Login.Msg
    | EditLoginMsg EditLogin.Msg
    | EditContactMsg EditContact.Msg
    | ReAuthorize (WebData User.AuthStatus)
    | GetProductDetailsData (WebData PageData.ProductDetails)
    | GetNavigationData (WebData NavigationData)
    | GetAdvancedSearchData (WebData PageData.AdvancedSearch)
    | GetPageDetailsData (WebData StaticPage)
    | GetLocationsData (WebData PageData.LocationData)
    | GetContactDetails (WebData PageData.ContactDetails)
    | CategoryPaginationMsg (Paginate.Msg ProductData PageData.CategoryDetails)
    | SearchPaginationMsg (Paginate.Msg ProductData String)
