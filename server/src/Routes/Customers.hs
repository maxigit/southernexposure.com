{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
module Routes.Customers
    ( CustomerAPI
    , customerRoutes
    ) where

import Control.Exception.Safe (throwM, Exception, try)
import Control.Monad ((>=>), (<=<), when, void)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Data.Aeson (ToJSON(..), FromJSON(..), (.=), (.:), (.:?), withObject, object)
import Data.Int (Int64)
import Data.List (partition)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.Time.Clock (UTCTime, getCurrentTime, addUTCTime)
import Data.Typeable (Typeable)
import Database.Persist
    ( (=.), (==.), Entity(..), get, getBy, insertUnique, insert, update
    , selectList, delete, deleteWhere, getEntity, updateWhere, SelectOpt(Asc)
    )
import Database.Persist.Sql (toSqlKey)
import Servant
    ( (:>), (:<|>)(..), AuthProtect, ReqBody, JSON, Get, Post, Put
    , err403, err404, err500, QueryParam, Capture, Delete
    )

import Auth
import Models
import Models.Fields
    (ArmedForcesRegionCode, armedForcesRegion, Cents(..), creditLineItemTypes)
import Routes.CommonData
    ( AuthorizationData, toAuthorizationData, AddressData(..), toAddressData
    , fromAddressData, LoginParameters(..), validatePassword
    )
import Routes.Utils (generateUniqueToken, hashPassword)
import Server
import Validation (Validation(..))
import Workers (Task(..), enqueueTask)

import qualified Data.CAProvinceCodes as CACodes
import qualified Data.ISO3166_CountryCodes as CountryCodes
import qualified Data.StateCodes as StateCodes
import qualified Data.Text as T
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID4
import qualified Database.Esqueleto as E
import qualified Emails
import qualified Models.Fields as Fields
import qualified Validation as V


type CustomerAPI =
         "locations" :> LocationRoute
    :<|> "register" :> RegisterRoute
    :<|> "login" :> LoginRoute
    :<|> "logout" :> LogoutRoute
    :<|> "authorize" :> AuthorizeRoute
    :<|> "reset-request" :> ResetRequestRoute
    :<|> "reset-password" :> ResetPasswordRoute
    :<|> "my-account" :> MyAccountRoute
    :<|> "edit" :> EditDetailsRoute
    :<|> "addresses" :> AddressDetailsRoute
    :<|> "address-edit" :> AddressEditRoute
    :<|> "address-delete" :> AddressDeleteRoute

type CustomerRoutes =
         App LocationData
    :<|> (RegistrationParameters -> App (Cookied AuthorizationData))
    :<|> (LoginParameters -> App (Cookied AuthorizationData))
    :<|> App (Cookied ())
    :<|> (WrappedAuthToken -> AuthorizeParameters -> App (Cookied AuthorizationData))
    :<|> (ResetRequestParameters -> App ())
    :<|> (ResetPasswordParameters -> App (Cookied AuthorizationData))
    :<|> (WrappedAuthToken -> Maybe Int64 -> App (Cookied MyAccountDetails))
    :<|> (WrappedAuthToken -> EditDetailsParameters -> App (Cookied ()))
    :<|> (WrappedAuthToken -> App (Cookied AddressDetails))
    :<|> (WrappedAuthToken -> Int64 -> AddressData -> App (Cookied ()))
    :<|> (WrappedAuthToken -> Int64 -> App (Cookied ()))

customerRoutes :: CustomerRoutes
customerRoutes =
         locationRoute
    :<|> registrationRoute
    :<|> loginRoute
    :<|> logoutRoute
    :<|> authorizeRoute
    :<|> resetRequestRoute
    :<|> resetPasswordRoute
    :<|> myAccountRoute
    :<|> editDetailsRoute
    :<|> addressDetailsRoute
    :<|> addressEditRoute
    :<|> addressDeleteRoute


-- LOCATIONS


data Location a =
    Location
        { lCode :: a
        , lName :: T.Text
        }

instance (Show a) => ToJSON (Location a) where
    toJSON Location { lCode, lName } =
        object [ "code" .= toJSON (show lCode)
               , "name" .= toJSON lName
               ]

data LocationData =
    LocationData
        { ldCountries :: [Location CountryCodes.CountryCode]
        , ldUSStates :: [Location StateCodes.StateCode]
        , ldAFRegions :: [Location ArmedForcesRegionCode]
        , ldCAProvinces :: [Location CACodes.Code]
        }

instance ToJSON LocationData where
    toJSON LocationData { ldCountries, ldUSStates, ldAFRegions, ldCAProvinces } =
        object [ "countries" .= toJSON ldCountries
               , "states" .= toJSON ldUSStates
               , "armedForces" .= toJSON ldAFRegions
               , "provinces" .= toJSON ldCAProvinces
               ]

type LocationRoute =
    Get '[JSON] LocationData

locationRoute :: App LocationData
locationRoute =
    let
        initialCountries =
            [CountryCodes.US, CountryCodes.CA, CountryCodes.MX]

        countries =
            map (\c -> Location c . T.pack $ CountryCodes.readableCountryName c)
                $ initialCountries
                ++ filter (`notElem` initialCountries)
                    (enumFromTo minBound maxBound)
        states =
            map (uncurry $ flip Location) StateCodes.allStates

        armedForcesRegions =
            map (\r -> Location r $ armedForcesRegion r)
                $ enumFrom minBound

        provinces =
            map (\c -> Location c $ CACodes.toName c) CACodes.all
    in
        return LocationData
            { ldCountries = countries
            , ldUSStates = states
            , ldAFRegions = armedForcesRegions
            , ldCAProvinces = provinces
            }



-- REGISTER


data RegistrationParameters =
    RegistrationParameters
        { rpEmail :: T.Text
        , rpPassword :: T.Text
        , rpCartToken :: Maybe T.Text
        } deriving (Show)

instance FromJSON RegistrationParameters where
    parseJSON =
        withObject "RegistrationParameters" $ \v ->
            RegistrationParameters
                <$> v .: "email"
                <*> v .: "password"
                <*> v .:? "sessionToken"

instance Validation RegistrationParameters where
    -- TODO: Better validation, validate emails, compare to Zencart
    validators parameters = do
        emailDoesntExist <- V.uniqueCustomer $ rpEmail parameters
        return
            [ ( "email"
              , [ V.required $ rpEmail parameters
                , ( "An Account with this Email already exists."
                  , emailDoesntExist )
                ]
              )
            , ( "password"
              , [ V.required $ rpPassword parameters
                , V.minimumLength 8 $ rpPassword parameters
                ]
              )
            ]

type RegisterRoute =
       ReqBody '[JSON] RegistrationParameters
    :> Post '[JSON] (Cookied AuthorizationData)

registrationRoute :: RegistrationParameters -> App (Cookied AuthorizationData)
registrationRoute = validate >=> \parameters -> do
    encryptedPass <- hashPassword $ rpPassword parameters
    (authToken, customer, maybeCustomerId) <- runDB $ do
        authToken <- generateUniqueToken UniqueToken
        let customer = Customer
                { customerEmail = rpEmail parameters
                , customerStoreCredit = Cents 0
                , customerMemberNumber = ""
                , customerEncryptedPassword = encryptedPass
                , customerAuthToken = authToken
                , customerStripeId = Nothing
                , customerAvalaraCode = Nothing
                , customerIsAdmin = False
                }
        (authToken, customer,) <$> insertUnique customer
    case maybeCustomerId of
        Nothing ->
            serverError err500
        Just customerId ->
            runDB
                (maybeMergeCarts customerId (rpCartToken parameters)
                    >> enqueueTask Nothing (SendEmail $ Emails.AccountCreated customerId)
                )
            >> addSessionCookie temporarySession (AuthToken authToken)
                (toAuthorizationData $ Entity customerId customer)


-- LOGIN


type LoginRoute =
       ReqBody '[JSON] LoginParameters
    :> Post '[JSON] (Cookied AuthorizationData)

loginRoute :: LoginParameters -> App (Cookied AuthorizationData)
loginRoute lp@LoginParameters { lpCartToken, lpRemember } = do
    e@(Entity customerId customer) <- validatePassword lp
    runDB $ maybeMergeCarts customerId lpCartToken
    let sessionSettings = if lpRemember then permanentSession else temporarySession
    addSessionCookie sessionSettings (makeToken customer)
        $ toAuthorizationData e



-- LOGOUT


type LogoutRoute =
    Post '[JSON] (Cookied ())

logoutRoute :: App (Cookied ())
logoutRoute = removeSessionCookie ()


-- AUTHORIZE


newtype AuthorizeParameters =
    AuthorizeParameters
        { apUserId :: Int64
        }

instance FromJSON AuthorizeParameters where
    parseJSON = withObject "AuthorizeParameters" $ \v ->
        AuthorizeParameters
            <$> v .: "userId"

type AuthorizeRoute =
       AuthProtect "cookie-auth"
    :> ReqBody '[JSON] AuthorizeParameters
    :> Post '[JSON] (Cookied AuthorizationData)

authorizeRoute :: WrappedAuthToken -> AuthorizeParameters -> App (Cookied AuthorizationData)
authorizeRoute token AuthorizeParameters { apUserId } =
    let
        userId = toSqlKey apUserId
    in withCookie token $ \authToken -> do
        maybeCustomer <- runDB $ get userId
        case maybeCustomer of
            Just customer ->
                if fromAuthToken authToken == customerAuthToken customer then
                    return $ toAuthorizationData (Entity userId customer )
                else
                    serverError err403
            Nothing ->
                serverError err403


-- RESET PASSWORD


newtype ResetRequestParameters =
    ResetRequestParameters
        { rrpEmail :: T.Text
        }

instance FromJSON ResetRequestParameters where
    parseJSON = withObject "ResetRequestParameters" $ \v ->
        ResetRequestParameters <$> v .: "email"

instance Validation ResetRequestParameters where
    validators parameters =
        return [ ( "email", [V.required $ rrpEmail parameters] ) ]

type ResetRequestRoute =
       ReqBody '[JSON] ResetRequestParameters
    :> Post '[JSON] ()

resetRequestRoute :: ResetRequestParameters -> App ()
resetRequestRoute = validate >=> \parameters -> do
    maybeCustomer <- runDB . getCustomerByEmail $ rrpEmail parameters
    case maybeCustomer of
        Nothing ->
            (UUID.toText <$> liftIO UUID4.nextRandom)
            >> (addUTCTime (15 * 60) <$> liftIO getCurrentTime)
            >> return ()
        Just (Entity customerId _) -> do
            resetCode <- UUID.toText <$> liftIO UUID4.nextRandom
            expirationTime <- addUTCTime (15 * 60) <$> liftIO getCurrentTime
            let passwordReset =
                    PasswordReset
                        { passwordResetCustomerId = customerId
                        , passwordResetExpirationTime = expirationTime
                        , passwordResetCode = resetCode
                        }
            resetId <- runDB $ do
                deleteWhere [PasswordResetCustomerId ==. customerId]
                insert passwordReset
            cfg <- ask
            runDB (Emails.getEmailData (Emails.PasswordReset customerId resetId))
                >>= either (const $ return ()) (void . liftIO . Emails.sendWithRetries cfg)


data ResetPasswordParameters =
    ResetPasswordParameters
        { rppPassword :: T.Text
        , rppResetCode :: T.Text
        , rppCartToken :: Maybe T.Text
        }

instance FromJSON ResetPasswordParameters where
    parseJSON = withObject "ResetPasswordParameters" $ \v ->
        ResetPasswordParameters
            <$> v .: "password"
            <*> v .: "resetCode"
            <*> v .:? "sessionToken"

instance Validation ResetPasswordParameters where
    validators parameters =
        return
            [ ( "password"
              , [ V.required $ rppPassword parameters
                , V.minimumLength 8 $ rppPassword parameters
                ]
              )
            ]

type ResetPasswordRoute =
       ReqBody '[JSON] ResetPasswordParameters
    :> Post '[JSON] (Cookied AuthorizationData)

resetPasswordRoute :: ResetPasswordParameters -> App (Cookied AuthorizationData)
resetPasswordRoute = validate >=> \parameters ->
    let
        invalidCodeError =
            V.singleError $
                "Your reset code has expired, please try requesting a new " <>
                "password reset link."
    in do
        maybeResetRequest <- runDB . getBy . UniqueResetCode $ rppResetCode parameters
        case maybeResetRequest of
            Nothing ->
                invalidCodeError
            Just (Entity resetId passwordReset) -> do
                currentTime <- liftIO getCurrentTime
                if currentTime < passwordResetExpirationTime passwordReset then do
                    newHash <- hashPassword $ rppPassword parameters
                    let customerId = passwordResetCustomerId passwordReset
                    token <- runDB $ do
                        token <- generateUniqueToken UniqueToken
                        update customerId
                            [ CustomerAuthToken =. token
                            , CustomerEncryptedPassword =. newHash
                            ]
                        delete resetId
                        maybeMergeCarts customerId (rppCartToken parameters)
                        return token
                    maybeCustomer <- runDB $ get customerId
                    -- TODO: Something more relevant than invalidCodeError
                    flip (maybe invalidCodeError) maybeCustomer $ \customer -> do
                        runDB $ enqueueTask Nothing $ SendEmail $ Emails.PasswordResetSuccess customerId
                        addSessionCookie temporarySession (AuthToken token) . toAuthorizationData
                            $ Entity customerId customer
                else
                    runDB (delete resetId) >> invalidCodeError


-- MY ACCOUNT


data MyAccountDetails =
    MyAccountDetails
        { madOrderDetails :: [MyAccountOrderDetails]
        , madStoreCredit :: Cents
        }

instance ToJSON MyAccountDetails where
    toJSON details =
        object
            [ "orderDetails" .= madOrderDetails details
            , "storeCredit" .= madStoreCredit details
            ]

data MyAccountOrderDetails =
    MyAccountOrderDetails
        { maodId :: OrderId
        , maodShippingAddress :: AddressData
        , maodOrderStatus :: Fields.OrderStatus
        , maodOrderTotal :: Cents
        , maodCreated :: UTCTime
        }

instance ToJSON MyAccountOrderDetails where
    toJSON details =
        object
            [ "id" .= maodId details
            , "shippingAddress" .= maodShippingAddress details
            , "status" .= maodOrderStatus details
            , "total" .= maodOrderTotal details
            , "created" .= maodCreated details
            ]

type MyAccountRoute =
       AuthProtect "cookie-auth"
    :> QueryParam "limit" Int64
    :> Get '[JSON] (Cookied MyAccountDetails)

myAccountRoute :: WrappedAuthToken -> Maybe Int64 -> App (Cookied MyAccountDetails)
myAccountRoute token maybeLimit = withValidatedCookie token $ \(Entity customerId customer) -> do
    orderDetails <- getOrderDetails customerId
    return $ MyAccountDetails orderDetails (customerStoreCredit customer)
    where getOrderDetails customerId = runDB $ do
            let limit = fromMaybe 4 maybeLimit
            orderData <- E.select $ E.from $
                \(o `E.InnerJoin` op `E.InnerJoin` sa) -> do
                    E.on $ sa E.^. AddressId E.==. o E.^. OrderShippingAddressId
                    E.on $ op E.^. OrderProductOrderId E.==. o E.^. OrderId
                    let lineTotal = E.sub_select $ E.from $ \ol_ -> do
                            E.where_ $ ol_ E.^. OrderLineItemOrderId E.==. o E.^. OrderId
                                E.&&. ol_ E.^. OrderLineItemType `E.notIn` E.valList creditLineItemTypes
                            return $ sum0_ $ ol_ E.^. OrderLineItemAmount
                        creditTotal = E.sub_select $ E.from $ \cl_ -> do
                            E.where_ $ cl_ E.^. OrderLineItemOrderId E.==. o E.^. OrderId
                                E.&&. cl_ E.^. OrderLineItemType `E.in_` E.valList creditLineItemTypes
                            return $ sum0_ $ cl_ E.^. OrderLineItemAmount
                    E.groupBy (o E.^. OrderId, sa E.^. AddressId)
                    E.where_ $ o E.^. OrderCustomerId E.==. E.val customerId
                    E.orderBy [E.desc $ o E.^. OrderCreatedAt]
                    when (limit > 0) $ E.limit limit
                    return
                        ( o E.^. OrderId
                        , sa
                        , o E.^. OrderStatus
                        , calculateTotal op lineTotal creditTotal
                        , o E.^. OrderCreatedAt
                        )
            return $ map makeDetails orderData
          calculateTotal orderProduct lineTotal creditTotal =
            let
                productQuantity =
                    orderProduct E.^. OrderProductQuantity
                productPrice =
                    orderProduct E.^. OrderProductPrice
                subTotal =
                    sum0_ $ E.castNum productQuantity E.*. productPrice
            in
                subTotal E.+. lineTotal E.-. creditTotal
          makeDetails (orderId, shippingAddress, status, total, createdAt) =
              MyAccountOrderDetails
                { maodId = E.unValue orderId
                , maodShippingAddress = toAddressData shippingAddress
                , maodOrderStatus = E.unValue status
                , maodOrderTotal = Cents $ round (E.unValue total :: Rational)
                , maodCreated = E.unValue createdAt
                }
          -- Sum a column, defaulting to 0 for empty results or all NULL values
          sum0_ eValue = E.coalesceDefault [E.sum_ eValue] $ E.val 0


-- EDIT DETAILS


data EditDetailsParameters =
    EditDetailsParameters
        { edpEmail :: Maybe T.Text
        , edpPassword :: Maybe T.Text
        }

instance FromJSON EditDetailsParameters where
    parseJSON = withObject "EditDetailsParameters" $ \v ->
        EditDetailsParameters
            <$> v .:? "email"
            <*> v .:? "password"

instance Validation (EditDetailsParameters, Customer) where
    validators (parameters, customer) = do
        maybeEmailDoesntExist <- mapM V.uniqueCustomer $ edpEmail parameters
        return
            [ ( "email"
              , [ ( "An Account with this Email already exists."
                  , flip (maybe False) (edpEmail parameters) $ \e ->
                        fromMaybe False maybeEmailDoesntExist
                        && (e /= customerEmail customer)
                  )
                ]
              )
            , ( "password"
              , [ maybe ("", False) (V.minimumLength 8) $ edpPassword parameters
                ]
              )
            ]


type EditDetailsRoute =
       AuthProtect "cookie-auth"
    :> ReqBody '[JSON] EditDetailsParameters
    :> Put '[JSON] (Cookied ())

editDetailsRoute :: WrappedAuthToken -> EditDetailsParameters -> App (Cookied ())
editDetailsRoute token p = withValidatedCookie token $ \(Entity customerId customer) -> do
    (parameters, _) <- validate (p, customer)
    maybeHash <- mapM hashPassword $ edpPassword parameters
    void . runDB . update customerId $ updateFields (edpEmail parameters) maybeHash
    where updateFields maybeEmail maybePassword =
            maybe [] (\e -> [CustomerEmail =. e]) maybeEmail
                ++ maybe [] (\e -> [CustomerEncryptedPassword =. e]) maybePassword


-- ADDRESS DETAILS


data AddressDetails =
    AddressDetails
        { adShippingAddresses :: [AddressData]
        , adBillingAddresses :: [AddressData]
        }

instance ToJSON AddressDetails where
    toJSON details =
        object
            [ "shippingAddresses" .= adShippingAddresses details
            , "billingAddresses" .= adBillingAddresses details
            ]

type AddressDetailsRoute =
       AuthProtect "cookie-auth"
    :> Get '[JSON] (Cookied AddressDetails)

addressDetailsRoute :: WrappedAuthToken -> App (Cookied AddressDetails)
addressDetailsRoute token = withValidatedCookie token $ \(Entity customerId _) -> do
    addresses <- runDB $
        selectList [AddressCustomerId ==. customerId, AddressIsActive ==. True]
            [Asc AddressFirstName, Asc AddressLastName, Asc AddressAddressOne]
    let (shipping, billing) =
            partition (\a -> addressType (entityVal a) == Fields.Shipping) addresses
    return AddressDetails
        { adShippingAddresses = map toAddressData shipping
        , adBillingAddresses = map toAddressData billing
        }


-- EDIT ADDRESS


data AddressEditError
    = AddressNotFound
    deriving (Typeable, Show)

instance Exception AddressEditError

handleAddressError :: AddressEditError -> App a
handleAddressError = \case
    AddressNotFound ->
        serverError err404


type AddressEditRoute =
       AuthProtect "cookie-auth"
    :> Capture "id" Int64
    :> ReqBody '[JSON] AddressData
    :> Post '[JSON] (Cookied ())

addressEditRoute :: WrappedAuthToken -> Int64 -> AddressData -> App (Cookied ())
addressEditRoute token aId addressData = withValidatedCookie token $ \(Entity customerId _) -> do
    void $ validate addressData
    either handleAddressError return <=< try . runDB $ do
        let addressId = toSqlKey aId
        getEntity addressId >>= \case
            Nothing ->
                throwM AddressNotFound
            Just address
                | addressCustomerId (entityVal address) /= customerId ->
                    throwM AddressNotFound
                | toAddressData address == addressData ->
                    return ()
                | otherwise -> do
                    let addrType = addressType $ entityVal address
                    when (adIsDefault addressData) $
                        updateWhere
                            [ AddressCustomerId ==. customerId
                            , AddressType ==. addrType
                            ]
                            [ AddressIsDefault =. False ]
                    update addressId
                        [ AddressIsActive =. False
                        , AddressIsDefault =. False
                        ]
                    void . insertOrActivateAddress
                        $ fromAddressData addrType customerId addressData


type AddressDeleteRoute =
       AuthProtect "cookie-auth"
    :> Capture "id" Int64
    :> Delete '[JSON] (Cookied ())

addressDeleteRoute :: WrappedAuthToken -> Int64 -> App (Cookied ())
addressDeleteRoute token aId = withValidatedCookie token $ \(Entity customerId _) -> do
    let addressId = toSqlKey aId :: AddressId
    either handleAddressError return <=< try . runDB $ do
        address <- get addressId >>= maybe (throwM AddressNotFound) return
        if addressCustomerId address /= customerId then
            throwM AddressNotFound
        else
            update addressId [AddressIsActive =. False, AddressIsDefault =. False]


-- UTILS


maybeMergeCarts :: CustomerId -> Maybe T.Text -> AppSQL ()
maybeMergeCarts customerId =
    maybe (return ()) (`mergeAnonymousCart` customerId)
