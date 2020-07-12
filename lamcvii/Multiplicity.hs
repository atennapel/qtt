module Multiplicity where

import Lexer(Span,Charray,showSpan)
import Data.Map
import Data.List(lookup,intercalate, elemIndex)
import Data.Maybe
import Data.Function

data Mult = Zero | One | Many deriving (Eq,Ord)

instance Show Mult where
  show Zero = "0"
  show One  = "1"
  show Many = "w"

times :: Mult -> Mult -> Mult
times Zero _ = Zero
times _ Zero = Zero
times One x  = x
times x  One = x
times _  _   = Many

plus :: Mult -> Mult -> Mult
plus Zero x   = x
plus One Zero = One
plus _   _    = Many

mmin :: Mult -> Mult -> Mult
mmin Zero _ = Zero
mmin _ Zero = Zero
mmin One _  = One
mmin _ One  = One
mmin _ _    = Many

intersect :: Mult -> Mult -> Mult
intersect Zero Zero = Zero
intersect One  One  = One
intersect _    _    = Many