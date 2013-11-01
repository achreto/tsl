{-# LANGUAGE ImplicitParams, FlexibleContexts, TupleSections, ScopedTypeVariables #-}

module ExprOps(mapExpr,
               exprCallees,
               isLExpr,
               isMemExpr,
               isLocalLHS,
               isConstExpr,
               isInstExpr,
               eval,
               evalInt,
               exprNoSideEffects,
               exprNoSideEffectsWithPtr,
               applyNoSideEffects,
               exprObjs,
               exprObjsRec,
               exprScalars) where

import Control.Monad.Error
import Data.Maybe
import Data.Bits
import Data.List
import Data.Tuple.Select
import qualified Data.Map as M

import Util hiding (name)
import TSLUtil
import Pos
import Name
import Template
import TemplateOps
import Type
import TypeOps
import Expr
import Spec
import Method
import MethodOps
import Const
import NS
import Val
import TVar
import StatementOps
import Ops

-- Map function over subexpression of expression
mapExpr :: (?spec::Spec) => (Scope -> Expr -> Expr) -> Scope -> Expr -> Expr
mapExpr f s e = 
    case f s e of
         EApply p m mas         -> EApply  p m (map (fmap $ mapExpr f s) mas)
         EField p st n          -> EField  p (mapExpr f s st) n
         EPField p st n         -> EPField p (mapExpr f s st) n
         EIndex p arr i         -> EIndex  p (mapExpr f s arr) (mapExpr f s i)
         EUnOp p op a           -> EUnOp   p op (mapExpr f s a)
         EBinOp p op a1 a2      -> EBinOp  p op (mapExpr f s a1) (mapExpr f s a2)
         ETernOp p a1 a2 a3     -> ETernOp p (mapExpr f s a1) (mapExpr f s a2) (mapExpr f s a3)
         ECase p c cs md        -> ECase   p (mapExpr f s c) (map (\(e1,e2) -> (mapExpr f s e1, mapExpr f s e2)) cs) (fmap (mapExpr f s) md)
         ECond p cs md          -> ECond   p (map (\(e1,e2) -> (mapExpr f s e1, mapExpr f s e2)) cs) (fmap (mapExpr f s) md)
         ESlice p e (l,h)       -> ESlice  p (mapExpr f s e) (mapExpr f s l, mapExpr f s h)
         EStruct p n (Left fs)  -> EStruct p n (Left $ map (mapSnd $ mapExpr f s) fs)
         EStruct p n (Right fs) -> EStruct p n (Right $ map (mapExpr f s) fs)
         e'                     -> e'

-- Find all methods invoked by the expression
exprCallees :: (?spec::Spec) => Scope -> Expr -> [(Pos, (Template, Method))]
exprCallees s (EApply  p mref mas)      = (p,getMethod s mref):(concatMap (exprCallees s) $ catMaybes mas)
exprCallees s (EField  _ e _)           = exprCallees s e
exprCallees s (EPField _ e _)           = exprCallees s e
exprCallees s (EIndex  _ e idx)         = exprCallees s e ++ exprCallees s idx
exprCallees s (EUnOp   _ _ e)           = exprCallees s e
exprCallees s (EBinOp  _ _ e1 e2)       = exprCallees s e1 ++ exprCallees s e2
exprCallees s (ETernOp _ e1 e2 e3)      = exprCallees s e1 ++ exprCallees s e2 ++ exprCallees s e3
exprCallees s (ECase   _ c cs md)       = exprCallees s c ++ 
                                          concatMap (\(e1,e2) -> exprCallees s e1 ++ exprCallees s e2) cs ++ 
                                          (fromMaybe [] $ fmap (exprCallees s) md)
exprCallees s (ECond   _ cs md)         = concatMap (\(e1,e2) -> exprCallees s e1 ++ exprCallees s e2) cs ++ 
                                          (fromMaybe [] $ fmap (exprCallees s) md)
exprCallees s (ESlice  _ e (l,h))       = exprCallees s e ++ exprCallees s l ++ exprCallees s h
exprCallees s (EStruct _ _ (Left fs))   = concatMap (exprCallees s . snd) fs
exprCallees s (EStruct _ _ (Right fs))  = concatMap (exprCallees s) fs
exprCallees _ _                         = []


-- Eval constant expression
eval :: (?spec::Spec,?scope::Scope) => ConstExpr -> TVal
eval e = let t = typ e
         in TVal t (eval' e t)

eval' :: (?spec::Spec, ?scope::Scope) => ConstExpr -> Type -> Val
eval' (ETerm _ n) t           = case getTerm ?scope n of
                                     ObjConst s' c -> let ?scope = s' 
                                                      in eval' (constVal c) t
                                     ObjEnum _ e   -> EnumVal $ name e
eval' (ELit _ w _ _ v) _      = IntVal v
eval' (EBool _ b) _           = BoolVal b
eval' (EField _ e f) _        = let StructVal v = val $ eval e
                                in val $ v M.! f
--eval' (EIndex _ a i) _        = let ArrayVal av = val $ eval a
--                                    iv          = evalInt i
--                                in val $ av !! (fromInteger iv)
eval' (EUnOp _ op e) _ | isArithUOp op = let i = evalInt e
                                         in IntVal $ sel1 $ arithUOp op (i, typeSigned e, typeWidth e)
eval' (EUnOp _ Not e) _       = BoolVal $ not $ evalBool e
eval' (EUnOp _ AddrOf e) _    = PtrVal e
eval' (EBinOp  _ Eq e1 e2) _  = BoolVal $ eval e1 == eval e2
eval' (EBinOp  _ Neq e1 e2) _ = BoolVal $ eval e1 /= eval e2
eval' (EBinOp  _ Lt e1 e2) _  = BoolVal $ eval e1 <  eval e2
eval' (EBinOp  _ Gt e1 e2) _  = BoolVal $ eval e1 >  eval e2
eval' (EBinOp  _ Lte e1 e2) _ = BoolVal $ eval e1 <= eval e2
eval' (EBinOp  _ Gte e1 e2) _ = BoolVal $ eval e1 >= eval e2
eval' (EBinOp  _ op e1 e2) _ | elem op [And,Or,Imp] = 
                                let b1 = evalBool e1
                                    b2 = evalBool e2
                                in BoolVal $ case op of
                                                  And -> b1 && b2
                                                  Or  -> b1 || b2
                                                  Imp -> (not b1) || b2
eval' (EBinOp  _ op e1 e2) _ | isArithBOp op = 
                                let i1 = evalInt e1
                                    i2 = evalInt e2
                                in IntVal $ sel1 $ arithBOp op (i1, typeSigned e1, typeWidth e1) (i2, typeSigned e1, typeWidth e2)
eval' (ETernOp _ e1 e2 e3) _  = if evalBool e1
                                   then val $ eval e2
                                   else val $ eval e3
eval' (ECase _ e cs md) _     = case find (\(c,v) -> eval c == eval e) cs of
                                     Just (c,v) -> val $ eval v
                                     Nothing    -> val $ eval $ fromJustMsg ("Non-exhaustive case-expression") md
eval' (ECond _ cs md) _       = case find (evalBool . fst) cs of
                                     Just (c,v) -> val $ eval v
                                     Nothing    -> val $ eval $ fromJustMsg ("Non-exhaustive cond-expression") md
eval' (ESlice _ e (l,h)) _    = let v  = evalInt e
                                    l' = fromInteger $ evalInt l
                                    h' = fromInteger $ evalInt h
                                in IntVal $ 
                                   foldl' (\a idx -> case testBit v idx of
                                                          True  -> a + bit (idx - l')
                                                          False -> a)
                                          0 [l'..h']
eval' (EStruct _ n (Left fs)) _  = StructVal $ M.fromList $ map (mapSnd eval) fs
eval' (EStruct _ n (Right fs)) t = let StructSpec _ fs' = tspec $ typ' t
                                       fnames = map name fs'
                                   in StructVal $ M.fromList $ map (mapSnd eval) (zip fnames fs)
eval' (ENonDet _) _           = NondetVal


evalInt :: (?spec::Spec, ?scope::Scope) => ConstExpr -> Integer
evalInt e = let IntVal i = val $ eval e
            in i

evalBool :: (?spec::Spec, ?scope::Scope) => ConstExpr -> Bool
evalBool e = let BoolVal b = val $ eval e
             in b

-- L-expression: variable, field, array element,
isLExpr :: (?spec::Spec, ?scope::Scope) => Expr -> Bool
isLExpr (ETerm _ n)           = case getTerm ?scope n of
                                     ObjConst _ _ -> False
                                     ObjEnum  _ _ -> False
                                     ObjWire  _ _ -> False
                                     _            -> True
isLExpr (EField  _       e f) = isLExpr e &&
                                case objGet (ObjType $ typ e) f of
                                     ObjWire  _ _ -> False
                                     _            -> True
isLExpr (EPField _       e _) = True
isLExpr (EIndex  _       e _) = isLExpr e
isLExpr (ESlice  _       e _) = isLExpr e
isLExpr (EUnOp   _ Deref e  ) = True
isLExpr _                     = False

-- Mem-expression: like L-expression, but must additionally
-- refer to an in memory variable (i.e., the & operator must
-- make sense)
isMemExpr :: (?spec::Spec, ?scope::Scope) => Expr -> Bool
isMemExpr (ETerm _ n)           = case getTerm ?scope n of
                                     ObjConst _ _ -> False
                                     ObjEnum  _ _ -> False
                                     ObjWire  _ _ -> False
                                     ObjVar   _ v -> varMem v
                                     _            -> True
isMemExpr (EField  _       e f) = isMemExpr e &&
                                  case objGet (ObjType $ typ e) f of
                                       ObjWire  _ _ -> False
                                       _            -> True
isMemExpr (EPField _       e _) = True
isMemExpr (EIndex  _       e _) = isMemExpr e
isMemExpr (ESlice  _       e _) = isMemExpr e
isMemExpr (EUnOp   _ Deref e  ) = True
isMemExpr _                     = False



-- Check that L-expr refers to a local variable (used in checking side-effect 
-- freedom of expressions)
isLocalLHS :: (?spec::Spec, ?scope::Scope) => Expr -> Bool
isLocalLHS (ETerm _ n)         = case getTerm ?scope n of
                                      ObjVar _ _   -> True
                                      _            -> False
isLocalLHS (EField  _ e f)     = isLocalLHS e
isLocalLHS (EPField _ e _)     = False
isLocalLHS (EIndex  _ e _)     = isLocalLHS e
isLocalLHS (ESlice  _ e _)     = isLocalLHS e
isLocalLHS (EUnOp   _ Deref e) = False
isLocalLHS _                   = False


-- case/cond must be exhaustive
isConstExpr :: (?spec::Spec, ?scope::Scope) => Expr -> Bool
isConstExpr (ETerm _ n)              = case getTerm ?scope n of
                                            ObjConst _ _ -> True
                                            ObjEnum _ _  -> True
                                            _            -> False
isConstExpr (ELit _ _ _ _ _)         = True
isConstExpr (EBool _ _)              = True
isConstExpr (EApply _ _ _)           = False -- TODO: constant functions
isConstExpr (EField _ s _)           = isConstExpr s
isConstExpr (EPField _ _ _)          = False
isConstExpr (EIndex _ a i)           = False --isConstExpr a && isConstExpr i
isConstExpr (EUnOp _ _ e)            = isConstExpr e
isConstExpr (EBinOp _ _ e1 e2)       = isConstExpr e1 && isConstExpr e2
isConstExpr (ETernOp _ e1 e2 e3)     = isConstExpr e1 && isConstExpr e2 && isConstExpr e3
isConstExpr (ECase _ e cs md)        = isConstExpr e && 
                                       (and $ map (\(c,v) -> isConstExpr c && isConstExpr v) cs) &&
                                       case md of
                                            Just m -> isConstExpr m
                                            _      -> True
isConstExpr (ECond _ cs md)          = (and $ map (\(c,v) -> isConstExpr c && isConstExpr v) cs) &&
                                       case md of
                                            Just m -> isConstExpr m
                                            _      -> True
isConstExpr (ESlice _ e (l,h))       = isConstExpr e && isConstExpr l && isConstExpr h
isConstExpr (EStruct _ _ (Left fs))  = and $ map (isConstExpr . snd) fs
isConstExpr (EStruct _ _ (Right fs)) = and $ map isConstExpr fs
isConstExpr (ENonDet _)              = False


-- Side-effect free expressions

-- Treat pointer dereference as side-effect-free operation
exprNoSideEffectsWithPtr :: (?spec::Spec, ?scope::Scope) => Expr -> Bool
exprNoSideEffectsWithPtr e = let ?ptrok = True in exprNoSideEffects' e

-- Treat pointer dereference as potentially having side effects
exprNoSideEffects :: (?spec::Spec, ?scope::Scope) => Expr -> Bool
exprNoSideEffects e = let ?ptrok = False in exprNoSideEffects' e

exprNoSideEffects' :: (?spec::Spec, ?scope::Scope, ?ptrok::Bool) => Expr -> Bool
exprNoSideEffects' (EApply _ m mas)         = applyNoSideEffects m mas
exprNoSideEffects' (EField _ e _)           = exprNoSideEffects' e
exprNoSideEffects' (EPField _ e _)          = if' ?ptrok (exprNoSideEffects' e) False
exprNoSideEffects' (EIndex _ a i)           = exprNoSideEffects' a && exprNoSideEffects' i
exprNoSideEffects' (EUnOp _ Deref e)        = if' ?ptrok (exprNoSideEffects' e) False
exprNoSideEffects' (EUnOp _ _ e)            = exprNoSideEffects' e
exprNoSideEffects' (EBinOp _ _ e1 e2)       = exprNoSideEffects' e1 && exprNoSideEffects' e2
exprNoSideEffects' (ETernOp _ e1 e2 e3)     = exprNoSideEffects' e1 && exprNoSideEffects' e2 && exprNoSideEffects' e3
exprNoSideEffects' (ECase _ c cs md)        = exprNoSideEffects' c &&
                                              (and $ map (\(e1,e2) -> exprNoSideEffects' e1 && exprNoSideEffects' e2) cs) &&
                                              (and $ map exprNoSideEffects' $ maybeToList md)
exprNoSideEffects' (ECond _ cs md)          = (and $ map (\(e1,e2) -> exprNoSideEffects' e1 && exprNoSideEffects' e2) cs) &&
                                              (and $ map exprNoSideEffects' $ maybeToList md)
exprNoSideEffects' (ESlice _ e (l,h))       = exprNoSideEffects' e && exprNoSideEffects' l && exprNoSideEffects' h
exprNoSideEffects' (EStruct _ _ (Left fs))  = and $ map (exprNoSideEffects' . snd) fs 
exprNoSideEffects' (EStruct _ _ (Right fs)) = and $ map exprNoSideEffects' fs 
exprNoSideEffects' _                        = True

-- Check that method call is side-effect-free:
-- The method must be a function, all arguments must be side-effect-free 
-- expressions, and all out arguments must be local variables.
applyNoSideEffects :: (?spec::Spec, ?scope::Scope) => MethodRef -> [Maybe Expr] -> Bool
applyNoSideEffects mref mas =  (all isLocalLHS $ catMaybes oargs)     
                            && (methCat m == Function) 
                            && (all exprNoSideEffects $ catMaybes mas)
    where m       = snd $ getMethod ?scope mref
          oidx    = findIndices ((== ArgOut) . argDir) (methArg m)
          oargs   = map (mas !!) oidx

-- True if expression _can_ terminate instantaneously 
-- (but is not necessarily guaranteed to always do so)
isInstExpr :: (?spec::Spec, ?scope::Scope) => Expr -> Bool
isInstExpr (ETerm _ _)              = True
isInstExpr (ELit _ _ _ _ _)         = True
isInstExpr (EBool _ _)              = True
isInstExpr (EApply _ m mas)         = let (_,meth) = getMethod ?scope m
                                      in if elem (methCat meth) [Function,Procedure,Task Uncontrollable,Task Invisible]
                                            then all isInstExpr $ catMaybes mas 
                                            else False
isInstExpr (EField _ s _)           = isInstExpr s
isInstExpr (EPField _ s _)          = isInstExpr s
isInstExpr (EIndex _ a i)           = isInstExpr a && isInstExpr i
isInstExpr (EUnOp _ _ e)            = isInstExpr e
isInstExpr (EBinOp _ _ e1 e2)       = isInstExpr e1 && isInstExpr e2
isInstExpr (ETernOp _ e1 e2 e3)     = isInstExpr e1 && (isInstExpr e2 || isInstExpr e3)
isInstExpr (ECase _ c cs Nothing )  = isInstExpr c
isInstExpr (ECase _ c cs (Just d))  = isInstExpr c && (any isInstExpr $ d:(map snd cs))
isInstExpr (ECond _ cs Nothing)     = True
isInstExpr (ECond _ cs (Just d))    = any isInstExpr $ d:(map snd cs)
isInstExpr (ESlice  _ e _)          = isInstExpr e
isInstExpr (EStruct _ _ (Left fs))  = all isInstExpr $ map snd fs
isInstExpr (EStruct _ _ (Right fs)) = all isInstExpr fs
isInstExpr (ENonDet _)              = True

-- Objects referred to by the expression
exprObjs :: (?spec::Spec, ?scope::Scope) => Expr -> [Obj]
exprObjs (ETerm   _ s)            = [getTerm ?scope s]
exprObjs (EApply  _ m mas)        = (let (t,meth) = getMethod ?scope m in ObjMethod t meth):
                                    (concatMap exprObjs $ catMaybes mas)
exprObjs (EField  _ e f)          = (objGet (ObjType $ typ e) f) : 
                                    exprObjs e
exprObjs (EPField _ e f)          = exprObjs e
exprObjs (EIndex  _ a i)          = exprObjs a ++ exprObjs i
exprObjs (EUnOp   _ op a1)        = exprObjs a1
exprObjs (EBinOp  _ op a1 a2)     = exprObjs a1 ++ exprObjs a2
exprObjs (ETernOp _ a1 a2 a3)     = exprObjs a1 ++ exprObjs a2 ++ exprObjs a3
exprObjs (ECase   _ c cs md)      = exprObjs c ++ 
                                    concatMap (\(e1,e2) -> exprObjs e1 ++ exprObjs e2) cs ++ 
                                    concatMap exprObjs (maybeToList md)
exprObjs (ECond   _ cs md)        = concatMap (\(e1,e2) -> exprObjs e1 ++ exprObjs e2) cs ++ 
                                    concatMap exprObjs (maybeToList md)
exprObjs (ESlice  _ e (l,h))      = exprObjs e ++ exprObjs l ++ exprObjs h
exprObjs (EStruct _ _ (Left fs))  = concatMap (exprObjs . snd) fs
exprObjs (EStruct _ _ (Right fs)) = concatMap exprObjs fs
exprObjs _                        = []

-- recursive version
exprObjsRec :: (?spec::Spec, ?scope::Scope) => Expr -> [Obj]
exprObjsRec e =
    let os = exprObjs e
        mos = filter (\o -> case o of
                                 ObjMethod _ _ -> True
                                 _             -> False) os
        os' = concatMap (\(ObjMethod t m) -> methObjsRec t m) mos
    in os ++ os'

maxType :: (?spec::Spec, ?scope::Scope, WithType a) => [a] -> Type
maxType xs = foldl' (\t x -> maxType2 t (typ x)) (typ $ head xs) (tail xs)

maxType2 :: (?spec::Spec,?scope::Scope) => Type -> Type -> Type
maxType2 t1 t2 = let Type s1 t1' = typ' t1
                     Type s2 t2' = typ' t2
                 in case (t1', t2') of
                      (BoolSpec _    , BoolSpec _)     -> t1
                      (SIntSpec p i1 , SIntSpec _ i2)  -> Type s1 $ SIntSpec p (max i1 i2)
                      (UIntSpec p i1 , UIntSpec _ i2)  -> Type s1 $ UIntSpec p (max i1 i2)
                      (FlexTypeSpec _, _)              -> t2
                      (_             , FlexTypeSpec _) -> t1
                      _                                -> t1

-- Assumes that expression has been validated first
instance (?spec::Spec,?scope::Scope) => WithType Expr where
    typ (ETerm   _ n)           = typ $ getTerm ?scope n
    typ (ELit    p w True _ _)  = Type ?scope $ SIntSpec p w
    typ (ELit    p w False _ _) = Type ?scope $ UIntSpec p w
    typ (EBool   p _)           = Type ?scope $ BoolSpec p
    typ (EApply  _ mref _)      = Type (ScopeTemplate t) $ fromJust $ methRettyp m where (t,m) = getMethod ?scope mref
    typ (EField  _ e f)         = typ $ objGet (ObjType $ typ e) f 
    typ (EPField _ e f)         = typ $ objGet (ObjType $ Type s t) f where Type s (PtrSpec _ t) = typ' e
    typ (EIndex  _ e i)         = Type s t where Type s (ArraySpec _ t _) = typ' e
    typ (EUnOp   p op e) | isArithUOp op = case arithUOpType op (s,w) of
                                                (True, w')  -> Type ?scope (SIntSpec p w')
                                                (False, w') -> Type ?scope (UIntSpec p w')
                                           where (s,w) = (typeSigned e, typeWidth e)
    typ (EUnOp   _ BNeg e)      = typ e
    typ (EUnOp   p Not e)       = Type ?scope $ BoolSpec p
    typ (EUnOp   _ Deref e)     = Type s t where Type s (PtrSpec _ t) = typ' e
    typ (EUnOp   p AddrOf e)    = Type s (PtrSpec p t) where Type s t = typ' e
    typ (EBinOp  p op e1 e2) | elem op [Eq,Neq,Lt,Gt,Lte,Gte,And,Or,Imp] = Type ?scope $ BoolSpec p
                             | isArithBOp op = case arithBOpType op (s1,w1) (s2,w2) of
                                                    (True, w')  -> Type ?scope (SIntSpec p w')
                                                    (False, w') -> Type ?scope (UIntSpec p w')
                                               where (s1,w1) = (typeSigned e1, typeWidth e1)
                                                     (s2,w2) = (typeSigned e2, typeWidth e2)
    typ (ETernOp _ _ e2 e3)     = maxType [e2, e3]
    typ (ECase _ _ cs md)       = maxType $ (map snd cs) ++ maybeToList md
    typ (ECond _ cs md)         = maxType $ (map snd cs) ++ maybeToList md
    typ (ESlice p e (l,h))      = Type ?scope $ UIntSpec p (fromInteger (evalInt h - evalInt l + 1))
    typ (EStruct p tn _)        = Type ?scope $ UserTypeSpec p tn
    typ (EAtLab p l)            = Type ?scope $ BoolSpec p
    typ (ENonDet p)             = Type ?scope $ FlexTypeSpec p


instance (?spec::Spec,?scope::Scope) => WithTypeSpec Expr where
    tspec = tspec . typ

exprScalars :: (?spec::Spec,?scope::Scope) => Expr -> [Expr]
exprScalars e = exprScalars' e (tspec $ typ' e)

exprScalars' :: (?spec::Spec,?scope::Scope) => Expr -> TypeSpec -> [Expr]
exprScalars' (EStruct _ tn (Right fs)) _                 = concatMap exprScalars         fs
exprScalars' (EStruct _ tn (Left fs))  _                 = concatMap (exprScalars . snd) fs
exprScalars' e                         (BoolSpec _)      = [e]
exprScalars' e                         (UIntSpec _ _)    = [e]
exprScalars' e                         (SIntSpec _ _)    = [e]
exprScalars' e                         (StructSpec _ fs) = concatMap (\f -> exprScalars $ EField nopos e (name f)) fs
exprScalars' e                         (EnumSpec _ _)    = [e]
exprScalars' e                         (PtrSpec _ _)     = [e]
exprScalars' e                         (ArraySpec _ _ l) = map (\idx -> EIndex nopos e (ELit nopos 32 False Rad10 (fromIntegral idx))) [0..len-1]
                                                           where (len::Int) = fromInteger $ evalInt l
