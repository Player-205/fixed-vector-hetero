{-# LANGUAGE ConstraintKinds         #-}
{-# LANGUAGE DataKinds               #-}
{-# LANGUAGE DefaultSignatures       #-}
{-# LANGUAGE FlexibleContexts        #-}
{-# LANGUAGE FlexibleInstances       #-}
{-# LANGUAGE KindSignatures          #-}
{-# LANGUAGE MagicHash               #-}
{-# LANGUAGE MultiParamTypeClasses   #-}
{-# LANGUAGE PolyKinds               #-}
{-# LANGUAGE RankNTypes              #-}
{-# LANGUAGE ScopedTypeVariables     #-}
{-# LANGUAGE TypeApplications        #-}
{-# LANGUAGE TypeFamilies            #-}
{-# LANGUAGE TypeOperators           #-}
{-# LANGUAGE UndecidableInstances    #-}
{-# LANGUAGE UndecidableSuperClasses #-}
{-# LANGUAGE BlockArguments          #-}
{-# LANGUAGE TemplateHaskell         #-}
{-# LANGUAGE QuasiQuotes             #-}
module Data.Vector.HFixed.Class (
    -- * Types and type classes
    -- ** N-ary functions
    Fn
  , Fun
  , TFun(..)
    -- ** Type functions
  , Proxy(..)
  , type (++)
  , Len
  , HomList
    -- ** Type classes
  , Arity(..)
  , ArityC(..)
  , (:&&:)
  , HVector(..)
  , tupleSize
  , HVectorF(..)
  , tupleSizeF
    -- *** Lookup in vector
  , Index(..)
  , TyLookup(..)
    -- ** CPS-encoded vector
  , ContVec
  , ContVecF(..)
  , cons
  , consF
    -- ** Interop with homogeneous vectors
  , HomArity(..)
  , homInspect
  , homConstruct
    -- * Operations of Fun
    -- ** Primitives for Fun
  , curryFun
  , uncurryFun
  , uncurryMany
  , curryMany
  , constFun
    -- ** Primitives for TFun
  , constTFun
  , curryTFun
  , uncurryTFun
  , shuffleTF
  , stepTFun
    -- ** More complicated functions
  , concatF
  , lensWorkerF
  , lensWorkerTF
    -- * Lens
  , Lens
  , Lens'
  ) where

import Data.Coerce
import Data.Complex          (Complex(..))
import Data.Functor.Identity (Identity(..))
import Data.Type.Equality    (type (==))

import           Data.Vector.Fixed.Cont   (Peano,PeanoNum(..),ArityPeano)
import qualified Data.Vector.Fixed                as F
import qualified Data.Vector.Fixed.Cont           as F (curryFirst)
import qualified Data.Vector.Fixed.Unboxed        as U
import qualified Data.Vector.Fixed.Primitive      as P
import qualified Data.Vector.Fixed.Storable       as S
import qualified Data.Vector.Fixed.Boxed          as B

import Unsafe.Coerce (unsafeCoerce)
import GHC.Exts (Proxy#,proxy#)
import GHC.TypeLits
import GHC.Generics hiding (S)

import Data.Vector.HFixed.TypeFuns

import qualified Language.Haskell.TH as TH
import Data.Traversable


----------------------------------------------------------------
-- Types
----------------------------------------------------------------

-- | Type family for N-ary function. Types of function parameters are
--   encoded as the list of types.
type family Fn (f :: α -> *) (as :: [α]) b where
  Fn f '[]      b = b
  Fn f (a : as) b = f a -> Fn f as b

-- | Newtype wrapper for function where all type parameters have same
--   type constructor. This type is required for writing function
--   which works with monads, appicatives etc.
newtype TFun f as b = TFun { unTFun :: Fn f as b }

-- | Newtype wrapper to work around of type families' lack of
--   injectivity.
type Fun = TFun Identity



----------------------------------------------------------------
-- Generic operations
----------------------------------------------------------------

-- | Type class for combining two constraint constructors. Those are
--   required for 'ArityC' type class.
class (c1 a, c2 a) => (:&&:) c1 c2 a

instance (c1 a, c2 a) => (:&&:) c1 c2 a

-- | Type class for dealing with N-ary function in generic way. Both
--   'accum' and 'apply' work with accumulator data types which are
--   polymorphic. So it's only possible to write functions which
--   rearrange elements in vector using plain ADT. It's possible to
--   get around it by using GADT as accumulator (See 'ArityC' and
--   function which use it)
--
--   This is also somewhat a kitchen sink module. It contains
--   witnesses which could be used to prove type equalities or to
--   bring instance in scope.
class Arity (xs :: [α]) where
  -- | Fold over /N/ elements exposed as N-ary function.
  accum :: (forall a as. t (a : as) -> f a -> t as)
        -- ^ Step function. Applies element to accumulator.
        -> (t '[] -> b)
        -- ^ Extract value from accumulator.
        -> t xs
        -- ^ Initial state.
        -> TFun f xs b

  -- | Apply values to N-ary function
  apply :: (forall a as. t (a : as) -> (f a, t as))
        -- ^ Extract value to be applied to function.
        -> t xs
        -- ^ Initial state.
        -> ContVecF xs f

  -- | Size of type list as integer.
  arity :: p xs -> Int


class (Arity xs) => ArityC c xs where
  accumC :: proxy c
         -- ^
         -> (forall a as. (c a) => t (a : as) -> f a -> t as)
         -- ^ Step function. Applies element to accumulator.
         -> (t '[] -> b)
         -- ^ Extract value from accumulator.
         -> t xs
         -- ^ Initial state.
         -> TFun f xs b

  -- | Apply values to N-ary function
  applyC :: proxy c
         --
         -> (forall a as. (c a) => t (a : as) -> (f a, t as))
         -- ^ Extract value to be applied to function.
         -> t xs
         -- ^ Initial state.
         -> ContVecF xs f


instance Arity '[] where
  accum _ f t = TFun (f t)
  apply _ _   = ContVecF unTFun
  {-# INLINE accum #-}
  {-# INLINE apply #-}
  arity _     = 0
  {-# INLINE arity #-}

instance Arity xs => Arity (x : xs) where
  accum f g t = uncurryTFun (\a -> accum f g (f t a))
  apply f t   = case f t of (a,u) -> consF a (apply f u)
  {-# INLINE accum #-}
  {-# INLINE apply #-}
  arity _     = 1 + arity (Proxy :: Proxy xs)
  {-# INLINE arity        #-}

instance ArityC c '[] where
  accumC _ _ f t = TFun (f t)
  applyC _ _ _   = ContVecF unTFun
  {-# INLINE accumC #-}
  {-# INLINE applyC #-}

instance (c x, ArityC c xs) => ArityC c (x : xs) where
  accumC w f g t = uncurryTFun (\a -> accumC w f g (f t a))
  applyC w f t   = case f t of (a,u) -> consF a (applyC w f u)
  {-# INLINE accumC #-}
  {-# INLINE applyC #-}



-- |
-- Type class for product type. Any product type could have instance
-- of this type.  Its methods describe how to construct and
-- deconstruct data type. For example instance for simple data type
-- with two fields could be written as:
--
-- > data A a = A Int a
-- >
-- > instance HVector (A a) where
-- >   type Elems (A a) = '[Int,a]
-- >   construct = TFun $ \i a -> A i a
-- >   inspect (A i a) (TFun f) = f i a
--
-- Another equivalent description of this type class is descibes
-- isomorphism between data type and
-- 'Data.Vector.HFixed.Cont.ContVec', where @constuct@ implements
-- @ContVec → a@ (see 'Data.Vector.HFixed.Cont.vector') and @inspect@
-- implements @a → ContVec@ (see 'Data.Vector.HFixed.Cont.cvec')
--
-- Istances should satisfy one law:
--
-- > inspect v construct = v
--
-- Default implementation which uses 'Generic' is provided.
class Arity (Elems v) => HVector v where
  type Elems v :: [*]
  type Elems v = GElems (Rep v)
  -- | Function for constructing vector
  construct :: Fun (Elems v) v
  default construct :: (Generic v, GHVector (Rep v), GElems (Rep v) ~ Elems v)
                    => Fun (Elems v) v
  construct = fmap to gconstruct
  -- | Function for deconstruction of vector. It applies vector's
  --   elements to N-ary function.
  inspect :: v -> Fun (Elems v) a -> a
  default inspect :: (Generic v, GHVector (Rep v), GElems (Rep v) ~ Elems v)
                  => v -> Fun (Elems v) a -> a
  inspect v = ginspect (from v)
  {-# INLINE construct #-}
  {-# INLINE inspect   #-}

-- | Number of elements in product type
tupleSize :: forall v proxy. HVector v => proxy v -> Int
tupleSize _ = arity (Proxy :: Proxy (Elems v))

-- | Type class for partially homogeneous vector where every element
--   in the vector have same type constructor. Vector itself is
--   parametrized by that constructor
class Arity (ElemsF v) => HVectorF (v :: (α -> *) -> *) where
  -- | Elements of the vector without type constructors
  type ElemsF v :: [α]
  inspectF   :: v f -> TFun f (ElemsF v) a -> a
  constructF :: TFun f (ElemsF v) (v f)

-- | Number of elements in parametrized product type
tupleSizeF :: forall v f proxy. HVectorF v => proxy (v f) -> Int
tupleSizeF _a = arity (Proxy :: Proxy (ElemsF v))


----------------------------------------------------------------
-- Interop with homogeneous vectors
----------------------------------------------------------------

-- | Conversion between homogeneous and heterogeneous N-ary functions.
class (ArityPeano n, Arity (HomList n a)) => HomArity n a where
  -- | Convert n-ary homogeneous function to heterogeneous.
  toHeterogeneous :: F.Fun n a r -> Fun (HomList n a) r
  -- | Convert heterogeneous n-ary function to homogeneous.
  toHomogeneous   :: Fun (HomList n a) r -> F.Fun n a r


instance HomArity 'Z a where
  toHeterogeneous = coerce
  toHomogeneous   = coerce
  {-# INLINE toHeterogeneous #-}
  {-# INLINE toHomogeneous   #-}

instance HomArity n a => HomArity ('S n) a where
  toHeterogeneous f
    = coerce $ \a -> unTFun $ toHeterogeneous (F.curryFirst f a)
  toHomogeneous (f :: Fun (a : HomList n a) r)
    = coerce $ \a -> (toHomogeneous $ curryFun f a :: F.Fun n a r)
  {-# INLINE toHeterogeneous #-}
  {-# INLINE toHomogeneous   #-}

-- | Default implementation of 'inspect' for homogeneous vector.
homInspect :: (F.Vector v a, HomArity (Peano (F.Dim v)) a)
           => v a -> Fun (HomList (Peano (F.Dim v)) a) r -> r
homInspect v f = F.inspect v (toHomogeneous f)
{-# INLINE homInspect #-}

-- | Default implementation of 'construct' for homogeneous vector.
homConstruct :: forall v a.
                (F.Vector v a, HomArity (Peano (F.Dim v)) a)
             => Fun (HomList (Peano (F.Dim v)) a) (v a)
homConstruct = toHeterogeneous (F.construct :: F.Fun (Peano (F.Dim v)) a (v a))
{-# INLINE homConstruct #-}



instance ( HomArity (Peano n) a
         , KnownNat n
         , Peano (n + 1) ~ 'S (Peano n)
         ) => HVector (B.Vec n a) where
  type Elems (B.Vec n a) = HomList (Peano n) a
  inspect   = homInspect
  construct = homConstruct
  {-# INLINE inspect   #-}
  {-# INLINE construct #-}

instance ( U.Unbox n a
         , HomArity (Peano n) a
         , KnownNat n
         , Peano (n + 1) ~ 'S (Peano n)
         ) => HVector (U.Vec n a) where
  type Elems (U.Vec n a) = HomList (Peano n) a
  inspect   = homInspect
  construct = homConstruct
  {-# INLINE inspect   #-}
  {-# INLINE construct #-}

instance ( S.Storable a
         , HomArity (Peano n) a
         , KnownNat n
         , Peano (n + 1) ~ 'S (Peano n)
         ) => HVector (S.Vec n a) where
  type Elems (S.Vec n a) = HomList (Peano n) a
  inspect   = homInspect
  construct = homConstruct
  {-# INLINE inspect   #-}
  {-# INLINE construct #-}

instance ( P.Prim a
         , HomArity (Peano n) a
         , KnownNat n
         , Peano (n + 1) ~ 'S (Peano n)
         ) => HVector (P.Vec n a) where
  type Elems (P.Vec n a) = HomList (Peano n) a
  inspect   = homInspect
  construct = homConstruct
  {-# INLINE inspect   #-}
  {-# INLINE construct #-}



----------------------------------------------------------------
-- CPS-encoded vectors
----------------------------------------------------------------

--
-- newtype ContVec xs = ContVec { runContVec :: forall r. Fun xs r -> r }

instance Arity xs => HVector (ContVecF xs Identity) where
  type Elems (ContVecF xs Identity) = xs
  construct = accum
    (\(T_mkN f) (Identity x) -> T_mkN (f . cons x))
    (\(T_mkN f)              -> f (ContVecF unTFun))
    (T_mkN id)
  inspect (ContVecF cont) f = cont f
  {-# INLINE construct #-}
  {-# INLINE inspect   #-}

newtype T_mkN all xs = T_mkN (ContVec xs -> ContVec all)

-- | CPS-encoded heterogeneous vector.
type ContVec xs = ContVecF xs Identity

-- | CPS-encoded partially heterogeneous vector.
newtype ContVecF (xs :: [α]) (f :: α -> *) =
  ContVecF { runContVecF :: forall r. TFun f xs r -> r }

instance Arity xs => HVectorF (ContVecF xs) where
  type ElemsF (ContVecF xs) = xs
  inspectF (ContVecF cont) = cont
  constructF = constructFF
  {-# INLINE constructF #-}
  {-# INLINE inspectF   #-}

constructFF :: forall f xs. (Arity xs) => TFun f xs (ContVecF xs f)
{-# INLINE constructFF #-}
constructFF = accum (\(TF_mkN f) x -> TF_mkN (f . consF x))
                    (\(TF_mkN f)   -> f $ ContVecF unTFun)
                    (TF_mkN id)

newtype TF_mkN f all xs = TF_mkN (ContVecF xs f -> ContVecF all f)


-- | Cons element to the vector
cons :: x -> ContVec xs -> ContVec (x : xs)
cons x (ContVecF cont) = ContVecF $ \f -> cont $ curryFun f x
{-# INLINE cons #-}

-- | Cons element to the vector
consF :: f x -> ContVecF xs f -> ContVecF (x : xs) f
consF x (ContVecF cont) = ContVecF $ \f -> cont $ curryTFun f x
{-# INLINE consF #-}



----------------------------------------------------------------
-- Instances of Fun
----------------------------------------------------------------

instance (Arity xs) => Functor (TFun f xs) where
  fmap f (TFun g0)
    = accum (\(TF_fmap g) a -> TF_fmap (g a))
            (\(TF_fmap r)   -> f r)
            (TF_fmap g0)
  {-# INLINE fmap #-}

instance (Arity xs) => Applicative (TFun f xs) where
  pure r = accum (\Proxy _ -> Proxy)
                 (\Proxy   -> r)
                 (Proxy)
  {-# INLINE pure  #-}
  (TFun f0 :: TFun f xs (a -> b)) <*> (TFun g0 :: TFun f xs a)
    = accum (\(TF_ap f g) a -> TF_ap (f a) (g a))
            (\(TF_ap f g)   -> f g)
            ( TF_ap f0 g0 :: TF_ap f (a -> b) a xs)
  {-# INLINE (<*>) #-}

instance Arity xs => Monad (TFun f xs) where
  return  = pure
  f >>= g = shuffleTF g <*> f
  {-# INLINE return #-}
  {-# INLINE (>>=)  #-}

newtype TF_fmap f a   xs = TF_fmap (Fn f xs a)
data    TF_ap   f a b xs = TF_ap   (Fn f xs a) (Fn f xs b)



----------------------------------------------------------------
-- Operations on Fun
----------------------------------------------------------------

-- | Apply single parameter to function
curryFun :: Fun (x : xs) r -> x -> Fun xs r
curryFun = coerce
{-# INLINE curryFun #-}

-- | Uncurry N-ary function.
uncurryFun :: (x -> Fun xs r) -> Fun (x : xs) r
uncurryFun = coerce
{-# INLINE uncurryFun #-}

-- | Conversion function
uncurryMany :: forall xs ys r. Arity xs => Fun xs (Fun ys r) -> Fun (xs ++ ys) r
-- NOTE: GHC is not smart enough to figure out that:
--
--       > Fn xs (Fn ys) r ~ Fn (xs ++ ys) r
--
--       It's possible to construct type safe definition but it's
--       quite complicated and increase compile time and may hurrt
--       performance
{-# INLINE uncurryMany #-}
uncurryMany = unsafeCoerce

-- | Curry first /n/ arguments of N-ary function.
curryMany :: forall xs ys r. Arity xs => Fun (xs ++ ys) r -> Fun xs (Fun ys r)
-- NOTE: See uncurryMany
{-# INLINE curryMany #-}
curryMany = unsafeCoerce


-- | Add one parameter to function which is ignored.
constFun :: Fun xs r -> Fun (x : xs) r
constFun = uncurryFun . const
{-# INLINE constFun #-}

-- | Add one parameter to function which is ignored.
constTFun :: TFun f xs r -> TFun f (x : xs) r
constTFun = uncurryTFun . const
{-# INLINE constTFun #-}

-- | Transform function but leave outermost parameter untouched.
stepTFun :: (TFun f xs a       -> TFun f ys b)
         -> (TFun f (x : xs) a -> TFun f (x : ys) b)
stepTFun g = uncurryTFun . fmap g . curryTFun
{-# INLINE stepTFun #-}

-- | Concatenate n-ary functions. This function combine results of
--   both N-ary functions and merge their parameters into single list.
concatF :: (Arity xs, Arity ys)
        => (a -> b -> c) -> Fun xs a -> Fun ys b -> Fun (xs ++ ys) c
{-# INLINE concatF #-}
concatF f funA funB = uncurryMany $ fmap go funA
  where
    go a = fmap (\b -> f a b) funB

-- | Helper for lens implementation.
lensWorkerF :: forall f r x y xs. (Functor f, Arity xs)
            => (x -> f y) -> Fun (y : xs) r -> Fun (x : xs) (f r)
{-# INLINE lensWorkerF #-}
lensWorkerF g f
  = uncurryFun
  $ \x -> (\r -> fmap (r $) (g x)) <$> shuffleTF (curryFun f)

-- | Helper for lens implementation.
lensWorkerTF :: forall f g r x y xs. (Functor f, Arity xs)
             => (g x -> f (g y))
             -> TFun g (y : xs) r
             -> TFun g (x : xs) (f r)
{-# INLINE lensWorkerTF #-}
lensWorkerTF g f
  = uncurryTFun
  $ \x -> (\r -> fmap (r $) (g x)) <$> shuffleTF (curryTFun f)


----------------------------------------------------------------
-- Operations on TFun
----------------------------------------------------------------

-- | Apply single parameter to function
curryTFun :: TFun f (x : xs) r -> f x -> TFun f xs r
curryTFun = coerce
{-# INLINE curryTFun #-}

-- | Uncurry single parameter
uncurryTFun :: (f x -> TFun f xs r) -> TFun f (x : xs) r
uncurryTFun = coerce
{-# INLINE uncurryTFun #-}

-- | Move first argument of function to its result. This function is
--   useful for implementation of lens.
shuffleTF :: forall f x xs r. Arity xs
          => (x -> TFun f xs r) -> TFun f xs (x -> r)
{-# INLINE shuffleTF #-}
shuffleTF fun0 = accum
  (\(TF_shuffle f) a -> TF_shuffle (\x -> f x a))
  (\(TF_shuffle f)   -> f)
  (TF_shuffle (fmap unTFun fun0))

data TF_shuffle f x r xs = TF_shuffle (x -> Fn f xs r)



----------------------------------------------------------------
-- Indexing
----------------------------------------------------------------

-- | Indexing of vectors
class ArityPeano n => Index (n :: PeanoNum) (xs :: [*]) where
  -- | Type at position n
  type ValueAt n xs :: *
  -- | List of types with n'th element replaced by /a/.
  type NewElems n xs a :: [*]
  -- | Getter function for vectors
  getF :: proxy n -> Fun xs (ValueAt n xs)
  -- | Putter function. It applies value @x@ to @n@th parameter of
  --   function.
  putF :: proxy n -> ValueAt n xs -> Fun xs r -> Fun xs r
  -- | Helper for implementation of lens
  lensF   :: (Functor f, v ~ ValueAt n xs)
          => proxy n -> (v -> f v) -> Fun xs r -> Fun xs (f r)
  -- | Helper for type-changing lens
  lensChF :: (Functor f)
          => proxy n -> (ValueAt n xs -> f a) -> Fun (NewElems n xs a) r -> Fun xs (f r)

instance Arity xs => Index 'Z (x : xs) where
  type ValueAt  'Z (x : xs)   = x
  type NewElems 'Z (x : xs) a = a : xs
  getF  _     = TFun $ \(Identity x) -> unTFun (pure x :: Fun xs x)
  putF  _ x f = constFun $ curryFun f x
  lensF   _     = lensWorkerF
  lensChF _     = lensWorkerF
  {-# INLINE getF    #-}
  {-# INLINE putF    #-}
  {-# INLINE lensF   #-}
  {-# INLINE lensChF #-}

instance Index n xs => Index ('S n) (x : xs) where
  type ValueAt  ('S n) (x : xs)   = ValueAt n xs
  type NewElems ('S n) (x : xs) a = x : NewElems n xs a
  getF    _   = constFun $ getF    (Proxy @n)
  putF    _ x = stepTFun $ putF    (Proxy @n) x
  lensF   _ f = stepTFun $ lensF   (Proxy @n) f
  lensChF _ f = stepTFun $ lensChF (Proxy @n) f
  {-# INLINE getF    #-}
  {-# INLINE putF    #-}
  {-# INLINE lensF   #-}
  {-# INLINE lensChF #-}


----------------------------------------------------------------
-- Type lookup
----------------------------------------------------------------

-- | Type class to supporty looking up value in product type by its
--   type. Latter must not contain two elements of type @x@.
class Arity xs => TyLookup x xs where
  lookupTFun :: TFun f xs (f x)

-- Case analysis for type equality
class Arity xs => TyLookupCase (eq :: Bool) x xs where
  lookupTFunCase :: Proxy# eq -> TFun f xs (f x)

-- List xs does not contain type x
class NoType                  x xs
class NoTypeCase (eq :: Bool) x xs
instance                             NoType a '[]
instance NoTypeCase (a == x) a xs => NoType a (x ': xs)
instance ( TypeError ('Text "Duplicate type found: " ':$$: 'ShowType a)
         )           => NoTypeCase 'True  a xs
instance NoType a xs => NoTypeCase 'False a xs


instance ( TypeError ('Text "Cannot find type: " ':$$: 'ShowType a)
         ) => TyLookup a '[] where
  lookupTFun = error "Unreachable"

-- Case analysis of type equality
instance ( Arity xs
         , TyLookupCase (a == x) a (x ': xs)
         ) => TyLookup a (x ': xs) where
  lookupTFun = lookupTFunCase (proxy# :: Proxy# (a == x))
  {-# INLINE lookupTFun #-}

-- Found x
instance ( Arity xs
         , NoType x xs
         ) => TyLookupCase 'True x (x ': xs) where
  lookupTFunCase _ = uncurryTFun pure
  {-# INLINE lookupTFunCase #-}

-- Go deeper
instance ( Arity xs
         , TyLookup a xs
         ) => TyLookupCase 'False a (x ': xs) where
  lookupTFunCase _ = uncurryTFun $ const lookupTFun
  {-# INLINE lookupTFunCase #-}


----------------------------------------------------------------
-- Instances
----------------------------------------------------------------

-- | Unit is empty heterogeneous vector
instance HVector () where
  type Elems () = '[]
  construct = TFun ()
  inspect () (TFun f) = f

instance HVector (Complex a) where
  type Elems (Complex a) = '[a,a]
  construct = TFun $ \(Identity r) (Identity i) -> (:+) r i
  inspect (r :+ i) f = coerce f r i
  {-# INLINE construct #-}
  {-# INLINE inspect   #-}


-- | Copy of lens type definition from lens package
type Lens s t a b = forall f. Functor f => (a -> f b) -> s -> f t

-- | Copy of type preserving lens definition from lens package
type Lens' s a = Lens s s a a

----------------------------------------------------------------
-- Generics
----------------------------------------------------------------

class GHVector (v :: * -> *) where
  type GElems v :: [*]
  gconstruct :: Fun (GElems v) (v p)
  ginspect   :: v p -> Fun (GElems v) r -> r


-- We simply skip metadata
instance (GHVector f, Arity (GElems f)) => GHVector (M1 i c f) where
  type GElems (M1 i c f) = GElems f
  gconstruct = fmap M1 gconstruct
  ginspect v = ginspect (unM1 v)
  {-# INLINE gconstruct #-}
  {-# INLINE ginspect   #-}


instance ( GHVector f, GHVector g, Arity (GElems f), Arity (GElems g)
         ) => GHVector (f :*: g) where
  type GElems (f :*: g) = GElems f ++ GElems g
  gconstruct = concatF (:*:) gconstruct gconstruct
  ginspect (f :*: g) fun
    = ginspect g $ ginspect f $ curryMany fun
  {-# INLINE gconstruct #-}
  {-# INLINE ginspect   #-}


instance ( TypeError ('Text "It's impossible to derive HVector for type without constructors")
         ) => GHVector V1 where
  type GElems V1 = TypeError ('Text "It's impossible to derive HVector for type without constructors")
  gconstruct = error "Unreachable"
  ginspect   = error "Unreachable"

instance ( TypeError ('Text "It's impossible to derive HVector for sum types")
         ) => GHVector (f :+: g) where
  type GElems (f :+: g) = TypeError ('Text "It's impossible to derive HVector for sum types")
  gconstruct = error "Unreachable"
  ginspect   = error "Unreachable"

-- Recursion is terminated by simple field
instance GHVector (K1 R x) where
  type GElems (K1 R x) = '[x]
  gconstruct               = TFun (K1 . runIdentity)
  ginspect (K1 x) (TFun f) = f (Identity x)
  {-# INLINE gconstruct #-}
  {-# INLINE ginspect   #-}


-- Unit types are empty vectors
instance GHVector U1 where
  type GElems U1      = '[]
  gconstruct          = coerce U1
  ginspect _ (TFun f) = f
  {-# INLINE gconstruct #-}
  {-# INLINE ginspect   #-}

-- ** tuple instances

concat <$> for [1 .. 32] \i -> do
  let typeOp op x y = TH.appT (TH.appT op x) y

  -- type variables a1, a2, a3...
  let types    = [ TH.varT (TH.mkName ("a" <> show x)) | x <- [1 .. i]]
  -- (a1,a2,a3,...) saturated typle type constructor
  let tupleTy  = foldl TH.appT (TH.tupleT i) types
  -- '[a1,a2,a3,...] typelevel list with all type variables
  let listTy   = foldr (typeOp TH.promotedConsT) TH.promotedNilT types
  -- type of tuple constructor, a1 -> a2 -> a3 -> ... -> (a1,a2,a3,...)
  let constrTy = foldr (typeOp TH.arrowT) tupleTy types

  -- expresstion of unsaturated tuple of needed arity
  let tuplConstr  = TH.conE (TH.tupleDataName i)

  -- names of variables, that would be used in inspect
  let values      = [ TH.mkName ("a" <> show x) | x <- [1 .. i]]
  -- name of function argument of inspect
  let f           = TH.mkName "f"
  -- pattern of tuple, that bounds all names to names from values
  let tuplPat     = TH.tupP (map TH.varP values)
  -- expression `coerce f`
  let appNil      = TH.appE (TH.varE 'coerce) (TH.varE f)
  -- application of all variables to `coerce f`
  let inspectBody = foldl TH.appE appNil (map TH.varE values)

  -- just \tuplPat f -> inspectBody
  let inspectLam = TH.lamE [tuplPat, TH.varP f] inspectBody

  [d|
    instance HVector $tupleTy where
      type Elems $tupleTy = $listTy
      construct = coerce ($tuplConstr :: $constrTy)
      inspect = $inspectLam
      {-# INLINE construct #-}
      {-# INLINE inspect   #-}
    |]
