{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralisedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE PatternSynonyms            #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeFamilies               #-}

-- | A simple ledger state that only holds ledger tables (and values).
--
-- This is useful when we only need a ledger state and ledger tables, but not
-- necessarily blocks with payloads (such as defined in @Test.Util.TestBlock@).
module Test.Util.LedgerStateOnlyTables (
    OTLedgerState
  , OTLedgerTables
  , pattern OTLedgerState
  , pattern OTLedgerTables
  ) where

import           Cardano.Binary (FromCBOR (..), ToCBOR (..))
import           GHC.Generics (Generic)
import           NoThunks.Class (NoThunks)
import           Ouroboros.Consensus.Ledger.Basics (LedgerState)
import           Ouroboros.Consensus.Ledger.Tables
                     (CanSerializeLedgerTables (..), CanStowLedgerTables (..),
                     CodecMK (..), HasLedgerTables (..), MapKind, NameMK (..),
                     ValuesMK)
import           Ouroboros.Consensus.Ledger.Tables.Utils (emptyLedgerTables)

{-------------------------------------------------------------------------------
  Simple ledger state
-------------------------------------------------------------------------------}

type OTLedgerState  k v = LedgerState  (OTBlock k v)
type OTLedgerTables k v = LedgerTables (OTLedgerState k v)

-- | An empty type for blocks, which is only used to record the types @k@ and
-- @v@.
data OTBlock k v

data instance LedgerState (OTBlock k v) (mk :: MapKind) = OTLedgerState {
    otlsLedgerState  :: ValuesMK k v
  , otlsLedgerTables :: OTLedgerTables k v mk
  }

deriving instance (Ord k, Eq v, Eq (mk k v))
               => Eq (OTLedgerState k v mk)
deriving stock instance (Show k, Show v, Show (mk k v))
                     => Show (OTLedgerState k v mk)

instance (ToCBOR k, FromCBOR k, ToCBOR v, FromCBOR v)
      => CanSerializeLedgerTables (OTLedgerState k v) where
  codecLedgerTables = OTLedgerTables $ CodecMK toCBOR toCBOR fromCBOR fromCBOR

{-------------------------------------------------------------------------------
  Stowable
-------------------------------------------------------------------------------}

instance (Ord k, Eq v, Show k, Show v, NoThunks k, NoThunks v)
    => CanStowLedgerTables (OTLedgerState k v) where
  stowLedgerTables OTLedgerState{otlsLedgerTables} =
    OTLedgerState (otltLedgerTables otlsLedgerTables) emptyLedgerTables

  unstowLedgerTables OTLedgerState{otlsLedgerState} =
    OTLedgerState
      (otltLedgerTables emptyLedgerTables)
      (OTLedgerTables otlsLedgerState)

{-------------------------------------------------------------------------------
  Simple ledger tables
-------------------------------------------------------------------------------}

instance (Ord k, Eq v, Show k, Show v, NoThunks k, NoThunks v)
      => HasLedgerTables (OTLedgerState k v) where
  newtype LedgerTables (OTLedgerState k v) mk = OTLedgerTables {
      otltLedgerTables :: mk k v
    } deriving Generic

  projectLedgerTables OTLedgerState{otlsLedgerTables} =
    otlsLedgerTables

  withLedgerTables st lt =
    st { otlsLedgerTables = lt }

  pureLedgerTables f =
    OTLedgerTables { otltLedgerTables = f }

  mapLedgerTables f OTLedgerTables{otltLedgerTables} =
    OTLedgerTables $ f otltLedgerTables

  traverseLedgerTables f OTLedgerTables{otltLedgerTables} =
    OTLedgerTables <$> f otltLedgerTables

  zipLedgerTables f l r =
    OTLedgerTables (f (otltLedgerTables l) (otltLedgerTables r))

  zipLedgerTablesA f l r =
    OTLedgerTables <$> f (otltLedgerTables l) (otltLedgerTables r)

  zipLedgerTables3 f l m r =
    OTLedgerTables $
      f (otltLedgerTables l) (otltLedgerTables m) (otltLedgerTables r)

  zipLedgerTables3A f l c r =
    OTLedgerTables <$>
      f (otltLedgerTables l) (otltLedgerTables c) (otltLedgerTables r)

  foldLedgerTables f OTLedgerTables{otltLedgerTables} =
    f otltLedgerTables

  foldLedgerTables2 f l r =
    f (otltLedgerTables l) (otltLedgerTables r)

  namesLedgerTables =
    OTLedgerTables { otltLedgerTables = NameMK "otltLedgerTables" }

deriving stock instance (Eq (mk k v))
               => Eq (OTLedgerTables k v mk)

deriving stock instance (Show (mk k v))
               => Show (OTLedgerTables k v mk)

deriving newtype instance NoThunks (mk k v)
               => NoThunks (OTLedgerTables k v mk)