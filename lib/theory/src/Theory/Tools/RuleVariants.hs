{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# LANGUAGE ViewPatterns               #-}
-- |
-- Copyright   : (c) 2010-2012 Benedikt Schmidt
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Benedikt Schmidt <beschmi@gmail.com>
-- Portability : GHC only
--
-- Variants of protocol rules.
module Theory.Tools.RuleVariants where

import           Term.Narrowing.Variants
import           Term.Rewriting.Norm
import           Theory.Model
import           Theory.Tools.EquationStore

import           Extension.Prelude
import           Logic.Connectives

import           Control.Applicative
import           Control.Monad.Bind
import           Control.Monad.Reader
import qualified Control.Monad.Trans.PreciseFresh as Precise

import qualified Data.Map                         as M
import qualified Data.Set                         as S
import           Data.Traversable                 (traverse)

import           Debug.Trace.Ignore

-- Variants of protocol rules
----------------------------------------------------------------------

-- | Compute the variants of a protocol rule.
--   1. Abstract away terms in facts with variables.
--   2. Compute variants of RHSs of equations.
--   3. Apply variant substitutions to equations
--      to obtain DNF of equations.
--   4. Simplify rule.
variantsProtoRule :: MaudeHandle -> ProtoRuleE -> ProtoRuleAC
variantsProtoRule hnd ru@(Rule ri prems0 concs0 acts0) =
    -- rename rule to decrease variable indices
    (`Precise.evalFresh` Precise.nothingUsed) . renamePrecise  $ convertRule `evalFreshAvoiding` ru
  where
    convertRule = do
        (abstrPsCsAs, bindings) <- abstrRule
        let eqsAbstr         = map swap (M.toList bindings)
            abstractedTerms  = map snd eqsAbstr
            abstractionSubst = substFromList eqsAbstr
            variantSubsts    = computeVariants (fAppList abstractedTerms) `runReader` hnd
            substs           = [ restrictVFresh (frees abstrPsCsAs) $
                                   removeRenamings $ ((`runReader` hnd) . normSubstVFresh')  $
                                   composeVFresh vsubst abstractionSubst
                               | vsubst <- variantSubsts ]

        case substs of
          [] -> error $ "variantsProtoRule: rule has no variants `"++show ru++"'"
          _  -> do
              -- x <- return (emptySubst, Just substs) --
              x <- simpDisjunction hnd (const False) (Disj substs)
              case trace (show ("SIMP",abstractedTerms,
                                "abstr", abstrPsCsAs,
                                "substs", substs,
                                "simpSubsts:", x)) x of
                -- the variants can be simplified to a single case
                (commonSubst, Nothing) ->
                  return $ makeRule abstrPsCsAs commonSubst trueDisj
                (commonSubst, Just freshSubsts) ->
                  return $ makeRule abstrPsCsAs commonSubst freshSubsts

    abstrRule = (`runBindT` noBindings) $ do
        -- first import all vars into binding to obtain nicer names
        mapM_ abstrTerm [ varTerm v | v <- frees (prems0, concs0, acts0) ]
        (,,) <$> mapM abstrFact prems0
             <*> mapM abstrFact concs0
             <*> mapM abstrFact acts0

    irreducible = irreducibleFunctionSymbols (mhMaudeSig hnd)
    abstrFact = traverse abstrTerm
    abstrTerm (viewTerm -> FApp (NonAC o) args) | o `S.member` irreducible =
        fAppNonAC o <$> mapM abstrTerm args
    abstrTerm t = do
        at :: LNTerm <- varTerm <$> importBinding (`LVar` sortOfLNTerm t) t (getHint t)
        return at
      where getHint (viewTerm -> Lit (Var v)) = lvarName v
            getHint _                         = "z"

    makeRule (ps, cs, as) subst freshSubsts0 =
        Rule (ProtoRuleACInfo ri (Disj freshSubsts) []) prems concs acts
      where prems = apply subst ps
            concs = apply subst cs
            acts  = apply subst as
            freshSubsts = map (restrictVFresh (frees (prems, concs, acts))) freshSubsts0

    trueDisj = [ emptySubstVFresh ]