{-# LANGUAGE UndecidableInstances #-}

module ErgoDex.PContracts.PPool where

import qualified GHC.Generics as GHC
import Generics.SOP (Generic, I (I))

import Plutarch
import Plutarch.Prelude
import Plutarch.DataRepr
import Plutarch.Lift
import Plutarch.Api.V1.Contexts
import Plutarch.Api.V1 (PTxOut, PMaybeData(PDJust))

import PExtra.Monadic (tcon, tlet, tletField, tmatch)
import PExtra.List (pelemAt)
import PExtra.API

import qualified ErgoDex.Contracts.Pool as P

newtype PoolConfig (s :: S) = PoolConfig
  (
    Term s (
      PDataRecord
        '[ "poolNft" ':= PAssetClass
         , "poolX"   ':= PAssetClass
         , "poolY"   ':= PAssetClass
         , "poolLq"  ':= PAssetClass
         , "feeNum"  ':= PInteger
         ]
    )
  )
  deriving stock (GHC.Generic)
  deriving anyclass (Generic, PIsDataRepr)
  deriving
    (PlutusType, PMatch, PIsData, PDataFields)
    via PIsDataReprInstances PoolConfig

instance PUnsafeLiftDecl PoolConfig where type PLifted PoolConfig = P.PoolConfig
deriving via (DerivePConstantViaData P.PoolConfig PoolConfig) instance (PConstant P.PoolConfig)

data PoolAction (s :: S) = Deposit | Redeem | Swap
instance PlutusType PoolAction where
  type PInner PoolAction _ = PInteger

  pcon' Deposit = 0
  pcon' Redeem = 1
  pcon' Swap = 2

  pmatch' x f =
    pif (x #== 0) (f Deposit)
      (pif (x #== 1) (f Redeem) (f Swap))

newtype PoolRedeemer (s :: S) = PoolRedeemer
  (
    Term s (
      PDataRecord
        '[ "action" ':= PoolAction
         , "selfix" ':= PInteger
         ]
    )
  )
  deriving stock (GHC.Generic)
  deriving anyclass (Generic, PIsDataRepr)
  deriving
    (PlutusType, PIsData, PDataFields)
    via PIsDataReprInstances PoolRedeemer

newtype PoolState (s :: S) = PoolState
  (
    Term s (
      PDataRecord
        '[ "reservesX" ':= PInteger
         , "reservesY" ':= PInteger
         , "liquidity" ':= PInteger
         ]
    )
  )
  deriving stock (GHC.Generic)
  deriving anyclass (Generic, PIsDataRepr)
  deriving
    (PlutusType, PIsData, PDataFields)
    via PIsDataReprInstances PoolState

newtype PoolDiff (s :: S) = PoolDiff
  (
    Term s (
      PDataRecord
        '[ "diffX"  ':= PInteger
         , "diffY"  ':= PInteger
         , "diffLq" ':= PInteger
         ]
    )
  )
  deriving stock (GHC.Generic)
  deriving anyclass (Generic, PIsDataRepr)
  deriving
    (PlutusType, PIsData, PDataFields)
    via PIsDataReprInstances PoolDiff

poolDiff :: Term s (PoolState :--> PoolState :--> PoolDiff)
poolDiff = plam $ \s0 s1 -> unTermCont $ do
  rx0 <- tletField @"reservesX" s0
  rx1 <- tletField @"reservesX" s1
  ry0 <- tletField @"reservesY" s0
  ry1 <- tletField @"reservesY" s1
  lq0 <- tletField @"liquidity" s0
  lq1 <- tletField @"liquidity" s1
  let
    dx  = rx1 - rx0
    dy  = ry1 - ry0
    dlq = lq0 - lq1 -- pool keeps only the negative part of LQ tokens
  tcon $ PoolDiff
     $ pdcons @"diffX" @PInteger # pdata dx
    #$ pdcons @"diffY" @PInteger # pdata dy
    #$ pdcons @"diffLq" @PInteger # pdata dlq
     # pdnil

maxLqCap :: Term s PInteger
maxLqCap = pconstant 0x7fffffffffffffff

feeDen :: Term s PInteger
feeDen = pconstant 1000

zero :: Term s PInteger
zero = pconstant 0

readPoolState :: Term s (PoolConfig :--> PTxOut :--> PoolState)
readPoolState = plam $ \conf' out -> unTermCont $ do
  value  <- tletField @"value" out
  poolX  <- tletField @"poolX" conf'
  poolY  <- tletField @"poolY" conf'
  poolLq <- tletField @"poolLq" conf'
  let
    x     = pdata $ assetClassValueOf # value # poolX
    y     = pdata $ assetClassValueOf # value # poolY
    negLq = assetClassValueOf # value # poolLq
    lq    = pdata $ maxLqCap - negLq
  tcon $ PoolState
     $ pdcons @"reservesX" @PInteger # x
    #$ pdcons @"reservesY" @PInteger # y
    #$ pdcons @"liquidity" @PInteger # lq
     # pdnil

pmin :: POrd a => Term s (a :--> a :--> a)
pmin = phoistAcyclic $ plam $ \a b -> pif (a #<= b) a b

tletUnwrap :: (PIsData a) => Term s (PAsData a) -> TermCont @r s (Term s a)
tletUnwrap = tlet . pfromData

validDeposit :: Term s (PoolState :--> PoolDiff :--> PBool)
validDeposit = plam $ \state' diff' -> unTermCont $ do
  state <- tcont $ pletFields @'["reservesX", "reservesY", "liquidity"] state'
  rx    <- tletUnwrap $ hrecField @"reservesX" state
  ry    <- tletUnwrap $ hrecField @"reservesY" state
  lq    <- tletUnwrap $ hrecField @"liquidity" state
  diff  <- tcont $ pletFields @'["diffX", "diffY", "diffLq"] diff'
  dx    <- tletUnwrap $ hrecField @"diffX" diff
  dy    <- tletUnwrap $ hrecField @"diffY" diff
  dlq   <- tletUnwrap $ hrecField @"diffLq" diff
  let liquidityUnlocked = pmin # (pdiv # (dx * lq) # rx) # (pdiv # (dy * lq) # ry) -- todo: this allows deposit shrinking attack
  pure $ dlq #<= liquidityUnlocked

validRedeem :: Term s (PoolState :--> PoolDiff :--> PBool)
validRedeem = plam $ \state' diff' -> unTermCont $ do
  state <- tcont $ pletFields @'["reservesX", "reservesY", "liquidity"] state'
  rx    <- tletUnwrap $ hrecField @"reservesX" state
  ry    <- tletUnwrap $ hrecField @"reservesY" state
  lq    <- tletUnwrap $ hrecField @"liquidity" state
  diff  <- tcont $ pletFields @'["diffX", "diffY", "diffLq"] diff'
  dx    <- tletUnwrap $ hrecField @"diffX" diff
  dy    <- tletUnwrap $ hrecField @"diffY" diff
  dlq   <- tletUnwrap $ hrecField @"diffLq" diff
  pure $ lq * rx #<= dx * lq #&& dlq * ry #<= dy * lq

validSwap :: Term s (PoolConfig :--> PoolState :--> PoolDiff :--> PBool)
validSwap = plam $ \conf state' diff' -> unTermCont $ do
  state   <- tcont $ pletFields @'["reservesX", "reservesY"] state'
  rx      <- tletUnwrap $ hrecField @"reservesX" state
  ry      <- tletUnwrap $ hrecField @"reservesY" state
  diff    <- tcont $ pletFields @'["diffX", "diffY", "diffLq"] diff'
  dx      <- tletUnwrap $ hrecField @"diffX" diff
  dy      <- tletUnwrap $ hrecField @"diffY" diff
  feeNum  <- tletField @"feeNum" conf
  feeDen' <- tlet feeDen
  pure $ pif (zero #< dx)
    (-dy * (rx * feeDen' + dx * feeNum) #<= ry * dx * feeDen')
    (-dx * (ry * feeDen' + dy * feeNum) #<= rx * dy * feeDen')

-- Guarantees preservation of pool NFT
findPoolOutput :: Term s (PAssetClass :--> PBuiltinList (PAsData PTxOut) :--> PAsData PTxOut)
findPoolOutput =
  phoistAcyclic $
    plam $ \nft ->
      precList
        (\self x xs ->
          let
            value = pfield @"value" # x
            amt   = assetClassValueOf # value # nft
          in pif (amt #== 1) x (self # xs))
        (const perror)

poolValidator :: Term s (PoolConfig :--> PoolRedeemer :--> PScriptContext :--> PBool)
poolValidator = plam $ \conf redeemer' ctx -> unTermCont $ do
  redeemer    <- tcont $ pletFields @'["action", "selfix"] redeemer'
  selfix      <- tletUnwrap $ hrecField @"selfix" redeemer
  txinfo      <- tletField @"txInfo" ctx
  inputs      <- tletField @"inputs" txinfo
  outputs     <- tletField @"outputs" txinfo
  selfIn      <- tlet $ pelemAt # selfix # inputs
  self        <- tletField @"resolved" selfIn
  nft         <- tletField @"poolNft" conf
  successor   <- tlet $ pfromData $ findPoolOutput # nft # outputs

  maybeSelfDh    <- tletField @"datumHash" self
  maybeSuccDh    <- tletField @"datumHash" successor
  PDJust selfDh' <- tmatch maybeSelfDh
  PDJust succDh' <- tmatch maybeSuccDh
  selfDh         <- tletField @"_0" selfDh'
  succDh         <- tletField @"_0" succDh'
  let confPreserved = succDh #== selfDh

  s0   <- tlet $ readPoolState # conf # self
  s1   <- tlet $ readPoolState # conf # successor
  diff <- tlet $ poolDiff # s0 # s1

  selfAddr <- tletField @"address" self
  succAddr <- tletField @"address" successor
  let scriptPreserved = succAddr #== selfAddr

  action      <- tletUnwrap $ hrecField @"action" redeemer
  validAction <- 


