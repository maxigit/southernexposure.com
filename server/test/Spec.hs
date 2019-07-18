import Data.Ratio ((%))
import Data.Text (Text)
import Data.Time (UTCTime(..), Day(..), DiffTime, secondsToDiffTime)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Numeric.Natural (Natural)
import Test.Tasty
import Test.Tasty.Hedgehog

import Models
import Models.Fields
import Routes.CommonData

main :: IO ()
main =
    defaultMain tests

tests :: TestTree
tests =
    testGroup "Tests" [commonData]

commonData :: TestTree
commonData =
    testGroup "CommonData Module" [ couponTests ]


couponTests :: TestTree
couponTests = testGroup "Coupon Discount Calculations"
    [ testProperty "Free Shipping" freeShipping
    , testProperty "Free Shipping with no methods" freeShippingNoMethods
    , testProperty "Percentage Discount" percentageDiscount
    , testProperty "Flat Discount" flatDiscount
    ]
  where
    couponWithType :: CouponType -> Gen Coupon
    couponWithType couponType = do
        coupon <- genCoupon
        return $ coupon { couponDiscount = couponType }
    freeShipping :: Property
    freeShipping = property $ do
        coupon <- forAll $ couponWithType FreeShipping
        shippingCharge <- forAll genCartCharge
        calculateCouponDiscount coupon [shippingCharge] 0 === ccAmount shippingCharge
    freeShippingNoMethods :: Property
    freeShippingNoMethods = property $ do
        coupon <- forAll $ couponWithType FreeShipping
        calculateCouponDiscount coupon [] 0 === 0
    percentageDiscount :: Property
    percentageDiscount = property $ do
        coupon <- forAll genCoupon
        percent <- case couponDiscount coupon of
            PercentageDiscount wholePercent ->
                return wholePercent
            _ ->
                forAll genWholePercentage
        let coupon_ = coupon { couponDiscount = PercentageDiscount percent }
        subTotal <- fromCents <$> forAll genCents
        calculateCouponDiscount coupon_ [] subTotal
            === Cents (round (toRational subTotal * (fromIntegral percent % 100)))
    flatDiscount :: Property
    flatDiscount = property $ do
        coupon <- forAll genCoupon
        amount <- case couponDiscount coupon of
            FlatDiscount amt ->
                return amt
            _ ->
                (+ 1) <$> forAll genCents
        let coupon_ = coupon { couponDiscount = FlatDiscount amount }
        subTotal <- forAll genCents
        let result = calculateCouponDiscount coupon_ [] (fromCents subTotal)
        if amount > subTotal then result === subTotal else result === amount






-- Generate an active coupon with minimum order size of 0 to $10.00
genCoupon :: Gen Coupon
genCoupon =
    Coupon
        <$> genText
        <*> genText
        <*> genText
        <*> pure True
        <*> genCouponType
        <*> genCentRange (Range.linear 0 1000)
        <*> genUTCTime
        <*> pure 0
        <*> pure 0
        <*> genUTCTime

genCouponType :: Gen CouponType
genCouponType =
    Gen.choice
        [ FlatDiscount <$> genCents
        , PercentageDiscount <$> genWholePercentage
        , pure FreeShipping
        ]

-- Generate charges of $0.01 to $10.00
genCartCharge :: Gen CartCharge
genCartCharge =
    CartCharge
        <$> genText
        <*> genCentRange (Range.linear 1 1000)


genCentRange :: Range Natural -> Gen Cents
genCentRange r =
    Cents <$> Gen.integral r

genCents :: Gen Cents
genCents = genCentRange $ Range.linear 0 999999

genWholePercentage :: Gen Percent
genWholePercentage = Gen.integral $ Range.linear 1 100

genText :: MonadGen m => m Text
genText = Gen.text (Range.linear 1 10) Gen.alpha

genUTCTime :: Gen UTCTime
genUTCTime =
    UTCTime
        <$> genDay
        <*> genTime
  where
    genDay :: Gen Day
    genDay = ModifiedJulianDay <$> Gen.integral (Range.linear 0 999999)
    genTime :: Gen DiffTime
    genTime = secondsToDiffTime <$> Gen.integral (Range.linear 0 86400)
