{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE EmptyCase             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}

-- | Strict variant of SOP
--
-- This does not currently attempt to be exhaustive.
module Data.SOP.Strict (
    -- * NP
    NP (..)
  , hd
  , map_NP'
  , npToSListI
  , singletonNP
  , tl
    -- * NS
  , NS (..)
  , index_NS
  , partition_NS
  , sequence_NS'
  , unZ
    -- * Injections
  , Injection
  , injections
    -- * fn
  , fn_5
    -- * Re-exports from @sop-core@
  , module Data.SOP
  , module Data.SOP.Constraint
  ) where

import           Data.Coerce
import           Data.Kind (Type)
import           Data.SOP hiding (Injection, NP (..), NS (..), hd, injections,
                     shiftInjection, tl, unZ)
import           Data.SOP.Classes (Same)
import           Data.SOP.Constraint
import           NoThunks.Class (NoThunks (..), allNoThunks)

{-------------------------------------------------------------------------------
  NP
-------------------------------------------------------------------------------}

data NP :: (k -> Type) -> [k] -> Type where
  Nil  :: NP f '[]
  (:*) :: !(f x) -> !(NP f xs) -> NP f (x ': xs)

infixr 5 :*

type instance CollapseTo NP a = [a]
type instance AllN       NP c = All c
type instance AllZipN    NP c = AllZip c
type instance Prod       NP   = NP
type instance SListIN    NP   = SListI
type instance Same       NP   = NP

singletonNP :: f x -> NP f '[x]
singletonNP fx = fx :* Nil

hd :: NP f (x ': xs) -> f x
hd (x :* _) = x

tl :: NP f (x ': xs) -> NP f xs
tl (_ :* xs) = xs

ap_NP :: NP (f -.-> g) xs -> NP f xs -> NP g xs
ap_NP Nil          Nil       = Nil
ap_NP (Fn f :* fs) (x :* xs) = f x :* ap_NP fs xs

pure_NP :: SListI xs => (forall a. f a) -> NP f xs
pure_NP = cpure_NP (Proxy @Top)

cpure_NP :: forall c xs proxy f. All c xs
         => proxy c -> (forall a. c a => f a) -> NP f xs
cpure_NP _ f = go sList
  where
    go :: All c xs' => SList xs' -> NP f xs'
    go SNil  = Nil
    go SCons = f :* go sList

collapse_NP :: NP (K a) xs -> [a]
collapse_NP = go
  where
    go :: NP (K a) xs -> [a]
    go Nil         = []
    go (K x :* xs) = x : go xs

ctraverse'_NP  ::
     forall c proxy xs f f' g. (All c xs,  Applicative g)
  => proxy c -> (forall a. c a => f a -> g (f' a)) -> NP f xs  -> g (NP f' xs)
ctraverse'_NP _ f = go
  where
    go :: All c ys => NP f ys -> g (NP f' ys)
    go Nil       = pure Nil
    go (x :* xs) = (:*) <$> f x <*> go xs

ctraverse__NP ::
     forall c proxy xs f g. (All c xs, Applicative g)
  => proxy c -> (forall a. c a => f a -> g ()) -> NP f xs -> g ()
ctraverse__NP _ f = go
  where
    go :: All c ys => NP f ys -> g ()
    go Nil       = pure ()
    go (x :* xs) = f x *> go xs

traverse__NP ::
     forall xs f g. (SListI xs, Applicative g)
  => (forall a. f a -> g ()) -> NP f xs -> g ()
traverse__NP f =
  ctraverse__NP (Proxy @Top) f

trans_NP ::
     AllZip c xs ys
  => proxy c
  -> (forall x y . c x y => f x -> g y)
  -> NP f xs -> NP g ys
trans_NP _ _t Nil       = Nil
trans_NP p  t (x :* xs) = t x :* trans_NP p t xs

coerce_NP ::
     forall f g xs ys .
     AllZip (LiftedCoercible f g) xs ys
  => NP f xs -> NP g ys
coerce_NP = trans_NP (Proxy @(LiftedCoercible f g)) coerce

-- | Version of 'map_NP' that does not require a singleton
map_NP' :: forall f g xs. (forall a. f a -> g a) -> NP f xs -> NP g xs
map_NP' f = go
  where
    go :: NP f xs' -> NP g xs'
    go Nil       = Nil
    go (x :* xs) = f x :* go xs

-- | Conjure up an 'SListI' constraint from an 'NP'
npToSListI :: NP a xs -> (SListI xs => r) -> r
npToSListI np = sListToSListI $ npToSList np
  where
    sListToSListI :: SList xs -> (SListI xs => r) -> r
    sListToSListI SNil  k = k
    sListToSListI SCons k = k

    npToSList :: NP a xs -> SList xs
    npToSList Nil       = SNil
    npToSList (_ :* xs) = sListToSListI (npToSList xs) SCons

instance HPure NP where
  hpure  = pure_NP
  hcpure = cpure_NP

instance HAp NP where
  hap = ap_NP

instance HCollapse NP where
  hcollapse = collapse_NP

instance HSequence NP where
  hctraverse' = ctraverse'_NP
  htraverse'  = hctraverse' (Proxy @Top)
  hsequence'  = htraverse' unComp

instance HTraverse_ NP where
  hctraverse_ = ctraverse__NP
  htraverse_  = traverse__NP

instance HTrans NP NP where
  htrans = trans_NP
  hcoerce = coerce_NP

{-------------------------------------------------------------------------------
  NS
-------------------------------------------------------------------------------}

data NS :: (k -> Type) -> [k] -> Type where
  Z :: !(f x) -> NS f (x ': xs)
  S :: !(NS f xs) -> NS f (x ': xs)

type instance CollapseTo NS a = a
type instance AllN       NS c = All c
type instance Prod       NS   = NP
type instance SListIN    NS   = SListI
type instance Same       NS   = NS

unZ :: NS f '[x] -> f x
unZ (Z x) = x

index_NS :: forall f xs . NS f xs -> Int
index_NS = go 0
  where
    go :: forall ys . Int -> NS f ys -> Int
    go !acc (Z _) = acc
    go !acc (S x) = go (acc + 1) x

expand_NS :: SListI xs => (forall x. f x) -> NS f xs -> NP f xs
expand_NS = cexpand_NS (Proxy @Top)

cexpand_NS :: forall c proxy f xs. All c xs
           => proxy c -> (forall x. c x => f x) -> NS f xs -> NP f xs
cexpand_NS p d = go
  where
    go :: forall xs'. All c xs' => NS f xs' -> NP f xs'
    go (Z x) = x :* hcpure p d
    go (S i) = d :* go i

ap_NS :: NP (f -.-> g) xs -> NS f xs -> NS g xs
ap_NS = go
  where
    go :: NP (f -.-> g) xs -> NS f xs -> NS g xs
    go (f :* _)  (Z x)  = Z $ apFn f x
    go (_ :* fs) (S xs) = S $ go fs xs
    go Nil       x      = case x of {}

collapse_NS :: NS (K a) xs -> a
collapse_NS = go
  where
    go :: NS (K a) xs  -> a
    go (Z (K x)) = x
    go (S xs)    = go xs

ctraverse'_NS  :: forall c proxy xs f f' g. (All c xs,  Functor g)
               => proxy c
               -> (forall a. c a => f a -> g (f' a))
               -> NS f xs  -> g (NS f' xs)
ctraverse'_NS _ f = go
  where
    go :: All c ys => NS f ys -> g (NS f' ys)
    go (Z x)  = Z <$> f x
    go (S xs) = S <$> go xs

trans_NS :: forall proxy c f g xs ys. AllZip c xs ys
         => proxy c
         -> (forall x y . c x y => f x -> g y)
         -> NS f xs -> NS g ys
trans_NS _ t = go
  where
    go :: AllZip c xs' ys' => NS f xs' -> NS g ys'
    go (Z x) = Z (t x)
    go (S x) = S (go x)

-- TODO: @sop-core@ defines this in terms of @unsafeCoerce@. Currently we
-- don't make much use of this function, so I prefer this more strongly
-- typed version.
coerce_NS :: forall f g xs ys. AllZip (LiftedCoercible f g) xs ys
          => NS f xs -> NS g ys
coerce_NS = trans_NS (Proxy @(LiftedCoercible f g)) coerce

-- | Version of 'sequence_NS' that requires only 'Functor'
--
-- The version in the library requires 'Applicative', which is unnecessary.
sequence_NS' :: forall xs f g. Functor f
             => NS (f :.: g) xs -> f (NS g xs)
sequence_NS' = go
  where
    go :: NS (f :.: g) xs' -> f (NS g xs')
    go (Z (Comp fx)) = Z <$> fx
    go (S r)         = S <$> go r

partition_NS :: forall xs f. SListI xs => [NS f xs] -> NP ([] :.: f) xs
partition_NS =
      foldr (hzipWith append) (hpure nil)
    . map (hexpand nil . hmap singleton)
  where
    nil :: ([] :.: f) a
    nil = Comp []

    singleton :: f a -> ([] :.: f) a
    singleton = Comp . (:[])

    append :: ([] :.: f) a -> ([] :.: f) a -> ([] :.: f) a
    append (Comp as) (Comp as') = Comp (as ++ as')

instance HExpand NS where
  hexpand  = expand_NS
  hcexpand = cexpand_NS

instance HAp NS where
  hap = ap_NS

instance HCollapse NS where
  hcollapse = collapse_NS

instance HSequence NS where
  hctraverse' = ctraverse'_NS
  htraverse'  = hctraverse' (Proxy @Top)
  hsequence'  = htraverse' unComp

instance HTrans NS NS where
  htrans  = trans_NS
  hcoerce = coerce_NS

{-------------------------------------------------------------------------------
  Injections
-------------------------------------------------------------------------------}

type Injection (f :: k -> Type) (xs :: [k]) = f -.-> K (NS f xs)

injections :: forall xs f. SListI xs => NP (Injection f xs) xs
injections = go sList
  where
    go :: SList xs' -> NP (Injection f xs') xs'
    go SNil  = Nil
    go SCons = fn (K . Z) :* hmap shiftInjection (go sList)

shiftInjection :: Injection f xs a -> Injection f (x ': xs) a
shiftInjection (Fn f) = Fn $ K . S . unK . f

{-------------------------------------------------------------------------------
  fn
-------------------------------------------------------------------------------}

fn_5 :: (f0 a -> f1 a -> f2 a -> f3 a -> f4 a -> f5 a)
     -> (f0 -.-> f1 -.-> f2 -.-> f3 -.-> f4 -.-> f5) a
fn_5 f = Fn $ \x0 ->
         Fn $ \x1 ->
         Fn $ \x2 ->
         Fn $ \x3 ->
         Fn $ \x4 ->
         f x0 x1 x2 x3 x4

{-------------------------------------------------------------------------------
  Instances
-------------------------------------------------------------------------------}

deriving instance All (Show `Compose` f) xs => Show (NS f xs)
deriving instance All (Eq   `Compose` f) xs => Eq   (NS f xs)
deriving instance (All (Eq `Compose` f) xs, All (Ord `Compose` f) xs) => Ord (NS f xs)

-- | Copied from sop-core
--
-- Not derived, since derived instance ignores associativity info
instance All (Show `Compose` f) xs => Show (NP f xs) where
  showsPrec _ Nil       = showString "Nil"
  showsPrec d (f :* fs) = showParen (d > 5)
                        $ showsPrec (5 + 1) f
                        . showString " :* "
                        . showsPrec 5 fs

deriving instance  All (Eq `Compose` f) xs                            => Eq  (NP f xs)
deriving instance (All (Eq `Compose` f) xs, All (Ord `Compose` f) xs) => Ord (NP f xs)

{-------------------------------------------------------------------------------
  NoThunks
-------------------------------------------------------------------------------}

instance All (Compose NoThunks f) xs
      => NoThunks (NS (f :: k -> Type) (xs :: [k])) where
  showTypeOf _ = "NS"
  wNoThunks ctxt = \case
      Z l -> noThunks ("Z" : ctxt) l
      S r -> noThunks ("S" : ctxt) r

instance All (Compose NoThunks f) xs
      => NoThunks (NP (f :: k -> Type) (xs :: [k])) where
  showTypeOf _ = "NP"
  wNoThunks ctxt = \case
      Nil     -> return Nothing
      x :* xs -> allNoThunks [
                     noThunks ("fst" : ctxt) x
                   , noThunks ("snd" : ctxt) xs
                   ]
