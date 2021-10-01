{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE MonoLocalBinds             #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE PartialTypeSignatures      #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# LANGUAGE ViewPatterns               #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# OPTIONS_GHC -Wno-simplifiable-class-constraints #-}
{-# OPTIONS_GHC -fno-strictness #-}
{-# OPTIONS_GHC -fno-specialise #-}
{-# OPTIONS_GHC -fno-omit-interface-pragmas #-}

module Dex.Contract.OnChain where

import           Ledger.Value
    ( AssetClass (..),
      symbols,
      assetClassValueOf,
      tokenName,
      currencySymbol,
      assetClass )
import           Ledger.Contexts        (ScriptContext(..), txInfoOutputs)
import qualified Ledger.Constraints     as Constraints
import qualified Ledger.Typed.Scripts   as Scripts
import           PlutusTx.Bool          as Bool
import qualified PlutusTx.Builtins      as Builtins
import           Plutus.V1.Ledger.Scripts (ValidatorHash(..))
import qualified PlutusTx
import qualified PlutusTx.Foldable      as Foldable
import Plutus.Contract
    ( endpoint,
      utxoAt,
      submitTxConstraints,
      submitTxConstraintsSpending,
      collectFromScript,
      select,
      type (.\/),
      Endpoint,
      Contract,
      AsContractError,
      ContractError )
import           Plutus.Contract.Schema ()
import           Plutus.Trace.Emulator  (EmulatorTrace)
import qualified Plutus.Trace.Emulator  as Trace
import           Plutus.V1.Ledger.Contexts
import           Plutus.V1.Ledger.Address as Address
import           PlutusTx.Builtins  (divideInteger, multiplyInteger, addInteger, subtractInteger)
import Ledger
    ( findOwnInput,
      getContinuingOutputs,
      ownHashes,
      txOutAddress,
      ScriptContext(scriptContextTxInfo),
      TxInInfo(txInInfoResolved),
      TxInfo(txInfoInputs),
      DatumHash,
      Redeemer,
      Address,
      TxOut(txOutDatumHash, txOutValue),
      Value,
      ValidatorHash,
      Validator,
      scriptHashAddress)
import qualified Ledger.Ada             as Ada

import qualified PlutusTx
import           PlutusTx.Prelude
import           Schema                 (ToArgument, ToSchema)
import           Wallet.Emulator        (Wallet (..))
import Dex.Contract.Models
import Utils
    ( amountOf,
      isUnity,
      outputAmountOf,
      Amount(unAmount),
      Coin(Coin),
      CoinA,
      CoinB,
      LPToken,
      lpSupply,
      findOwnInput',
      valueWithin,
      calculateValueInOutputs,
      ownOutput,
      check2outputs,
      check2inputs)

--todo: Refactoring. Check that value of ergo, ada is greather than 0. validate creation, adding ada/ergo to

data ErgoDexSwapping
instance Scripts.ValidatorTypes ErgoDexSwapping where
    type instance RedeemerType ErgoDexSwapping = ContractAction
    type instance DatumType    ErgoDexSwapping = ErgoDexPool

{-# INLINABLE checkTokenSwap #-}
checkTokenSwap :: ErgoDexPool -> ScriptContext -> Bool
checkTokenSwap ErgoDexPool{..} sCtx =
    traceIfFalse "Expected A or B coin to be present in input" checkSwaps PlutusTx.Prelude.&&
    traceIfFalse "Inputs qty check failed" (check2inputs sCtx) PlutusTx.Prelude.&&
    traceIfFalse "Outputs qty check failed" (check2outputs sCtx)
  where

    ownInput :: TxInInfo
    ownInput = findOwnInput' sCtx

    previousValue :: Value
    previousValue = txOutValue $ txInInfoResolved ownInput

    newValue :: Value
    newValue = txOutValue $ ownOutput sCtx

    checkCorrectnessSwap :: AssetClass -> AssetClass -> Bool
    checkCorrectnessSwap coinX coinY =
      let
        previousXValue = assetClassValueOf previousValue (coinX)
        previousYValue = assetClassValueOf previousValue (coinY)
        newXValue = assetClassValueOf newValue (coinX)
        newYValue = assetClassValueOf newValue (coinY)
        coinXToSwap = newXValue - previousXValue
        rate = newYValue `multiplyInteger` coinXToSwap `multiplyInteger` (feeNum) `divideInteger` (previousYValue `multiplyInteger` 1000 + coinXToSwap `multiplyInteger` (feeNum))
      in newYValue == (previousYValue `multiplyInteger` rate)

    checkSwaps :: Bool
    checkSwaps = checkCorrectnessSwap xCoin yCoin || checkCorrectnessSwap yCoin xCoin

{-# INLINABLE checkCorrectDepositing #-}
checkCorrectDepositing :: ErgoDexPool -> ScriptContext -> Bool
checkCorrectDepositing ErgoDexPool{..} sCtx =
  traceIfFalse "Incorrect lp token value" checkDeposit PlutusTx.Prelude.&&
  traceIfFalse "Inputs qty check failed" (check2inputs sCtx) PlutusTx.Prelude.&&
  traceIfFalse "Outputs qty check failed" (check2outputs sCtx)
  where

    ownInput :: TxInInfo
    ownInput = findOwnInput' sCtx

    previousValue :: Value
    previousValue = txOutValue $ txInInfoResolved ownInput

    newValue :: Value
    newValue = txOutValue $ ownOutput sCtx

    checkDeposit :: Bool
    checkDeposit =
      let
        previousXValue = assetClassValueOf previousValue (xCoin)
        previousYValue = assetClassValueOf previousValue (yCoin)
        previousLPValue = assetClassValueOf previousValue (lpCoin)
        newXValue = assetClassValueOf newValue (xCoin)
        newYValue = assetClassValueOf newValue (yCoin)
        newLPValue = assetClassValueOf newValue (lpCoin)
        coinXToDeposit = newXValue - previousXValue
        coinYToDeposit = newYValue - previousYValue
        deltaSupplyLP = newLPValue - previousLPValue
        sharesUnlocked = min (coinXToDeposit * lpSupply `divideInteger` previousXValue) (coinYToDeposit * lpSupply `divideInteger` previousYValue)
      in deltaSupplyLP <= sharesUnlocked

{-# INLINABLE checkCorrectRedemption #-}
checkCorrectRedemption :: ErgoDexPool -> ScriptContext -> Bool
checkCorrectRedemption ErgoDexPool{..} sCtx =
  traceIfFalse "Incorrect lp token value" checkRedemption PlutusTx.Prelude.&&
  traceIfFalse "Inputs qty check failed" (check2inputs sCtx) PlutusTx.Prelude.&&
  traceIfFalse "Outputs qty check failed" (check2outputs sCtx)
  where

    ownInput :: TxInInfo
    ownInput = findOwnInput' sCtx

    previousValue :: Value
    previousValue = txOutValue $ txInInfoResolved ownInput

    newValue :: Value
    newValue = txOutValue $ ownOutput sCtx

    checkRedemption :: Bool
    checkRedemption =
      let
        previousXValue = assetClassValueOf previousValue (xCoin)
        previousYValue = assetClassValueOf previousValue (yCoin)
        previousLPValue = assetClassValueOf previousValue (lpCoin)
        newXValue = assetClassValueOf newValue (xCoin)
        newYValue = assetClassValueOf newValue (yCoin)
        newLPValue = assetClassValueOf newValue (lpCoin)
        supplyLP0 = lpSupply - previousLPValue
        supplyLP1 = lpSupply - newLPValue
        lpReturned = newLPValue - previousLPValue
        deltaReservesX = newXValue - previousXValue
        deltaSupplyLP = newLPValue - previousLPValue
        deltaReservesY = newYValue - previousYValue
        correctXRedeem = deltaReservesX * supplyLP0 >= deltaSupplyLP * previousXValue
        correctYRedeem = deltaReservesY * supplyLP0 >= deltaSupplyLP * previousYValue
      in correctXRedeem && correctYRedeem

{-# INLINABLE mkDexValidator #-}
mkDexValidator :: ErgoDexPool -> ContractAction -> ScriptContext -> Bool
mkDexValidator pool SwapLP sCtx    = checkCorrectRedemption pool sCtx
mkDexValidator pool AddTokens sCtx = checkCorrectDepositing pool sCtx
mkDexValidator pool SwapToken sCtx = checkTokenSwap pool sCtx
mkDexValidator _ _ _ = False

{-# INLINABLE dexValidator #-}
dexValidator :: Validator
dexValidator = Scripts.validatorScript dexInstance

{-# INLINABLE dexContractHash #-}
dexContractHash :: ValidatorHash
dexContractHash = ValidatorHash Builtins.emptyByteString -- Scripts.tvValidatorHash dexInstance

{-# INLINABLE dexContractAddress #-}
dexContractAddress :: Address
dexContractAddress = scriptHashAddress dexContractHash

{-# INLINABLE inputLockedByDex #-}
inputLockedByDex :: ScriptContext -> Maybe TxInInfo
inputLockedByDex ScriptContext{scriptContextTxInfo=TxInfo{txInfoInputs}, scriptContextPurpose=Spending txOutRef} =
  Foldable.find (\TxInInfo{txInInfoResolved} -> toValidatorHash ( txOutAddress txInInfoResolved ) == Just dexContractHash ) txInfoInputs
inputLockedByDex _ = Nothing

{-# INLINABLE inputLockedByDex' #-}
inputLockedByDex' :: ScriptContext -> TxOut
inputLockedByDex' ctx = txInInfoResolved $ fromMaybe (error ()) (inputLockedByDex ctx)

dexInstance :: Scripts.TypedValidator ErgoDexSwapping
dexInstance = Scripts.mkTypedValidator @ErgoDexSwapping
    $$(PlutusTx.compile [|| mkDexValidator ||])
    $$(PlutusTx.compile [|| wrap ||]) where
        wrap = Scripts.wrapValidator @ErgoDexPool @ContractAction