{-# LANGUAGE ImplicitParams #-}

module ISpec(Goal(..),
             Transition(..),
             Spec(..),
             getVar,
             getEnumerator,
             getEnumeration,
             enumToInt) where

import Data.List
import Data.Maybe
import qualified Data.Map as M
import Text.PrettyPrint

import PP
import Util hiding (name)
import TSLUtil
import Ops
import IType
import IExpr
import IVar
import CFA

data Transition = Transition { tranFrom :: Loc
                             , tranTo   :: Loc
                             , tranCFA  :: CFA
                             }

instance PP Transition where
    pp (Transition from to cfa) = text "transition" <+> 
                                  (braces' $ text "init:" <+> pp from
                                             $+$
                                             text "final:" <+> pp to
                                             $+$
                                             pp cfa)

instance Show Transition where
    show = render . pp

data Goal = Goal { goalName :: String
                 , goalCond :: Transition
                 }

instance PP Goal where
    pp (Goal n c) = text "goal" <+> pp n <+> char '=' <+> pp c

data Spec = Spec { specEnum   :: [Enumeration]
                 , specVar    :: [Var]
                 , specCTran  :: [Transition]
                 , specUTran  :: [Transition]
                 , specWire   :: Transition
                 , specInit   :: (Transition, Expr) -- initial state constraint (constraint_on_spec_variables,constraints_on_aux_variables)
                 , specAlways :: Transition
                 , specGoal   :: [Goal] 
                 , specFair   :: [Expr]             -- sets of states f s.t. GF(-f)
                 }

instance PP Spec where
    pp s = (vcat $ map (($+$ text "") . pp) (specEnum s))
           $+$
           (vcat $ map (($+$ text "") . pp) (specVar s))
           $+$
           (vcat $ map (($+$ text "") . pp) (specCTran s))
           $+$
           (vcat $ map (($+$ text "") . pp) (specUTran s))
           $+$
           (text "wires: " <+> (pp $ specWire s))
           $+$
           (text "init: " <+> (pp $ fst $ specInit s))
           $+$
           (text "aux_init: " <+> (pp $ snd $ specInit s))
           $+$
           (text "always: " <+> (pp $ specAlways s))
           $+$
           (vcat $ map (($+$ text "") . pp) (specGoal s))
           $+$
           (vcat $ map (($+$ text "") . pp) (specFair s))

getVar :: (?spec::Spec) => String -> Var
getVar n = fromJustMsg ("getVar: variable " ++ n ++ " not found") 
                       $ find ((==n) . varName) $ specVar ?spec 

getEnumerator :: (?spec::Spec) => String -> Enumeration
getEnumerator e = fromJustMsg ("getEnumerator: enumerator " ++ e ++ " not found")
                  $ find (elem e . enumEnums) $ specEnum ?spec

getEnumeration :: (?spec::Spec) => String -> Enumeration
getEnumeration e = fromJustMsg ("getEnumeration: enumeration " ++ e ++ " not found")
                   $ find ((==e) . enumName) $ specEnum ?spec

-- Get sequence number of an enumerator
enumToInt :: (?spec::Spec) => String -> Int
enumToInt n = fst $ fromJust $ find ((==n) . snd) $ zip [0..] (enumEnums $ getEnumerator n)
