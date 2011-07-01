{-|

More generic matching, done in one step, unlike FilterSpec and filterJournal*. 
Currently used only by hledger-web.

-}

module Hledger.Data.Matching
where
import Data.Either
import Data.List
-- import Data.Map (findWithDefault, (!))
import Data.Maybe
-- import Data.Ord
import Data.Time.Calendar
-- import Data.Time.LocalTime
-- import Data.Tree
import Safe (readDef, headDef)
-- import System.Time (ClockTime(TOD))
import Test.HUnit
import Text.ParserCombinators.Parsec
-- import Text.Printf
-- import qualified Data.Map as Map

import Hledger.Utils
import Hledger.Data.Types
import Hledger.Data.AccountName
import Hledger.Data.Amount
-- import Hledger.Data.Commodity (canonicaliseCommodities)
import Hledger.Data.Dates
import Hledger.Data.Posting
import Hledger.Data.Transaction
-- import Hledger.Data.TimeLog

-- | A matcher is a single, or boolean composition of, search criteria,
-- which can be used to match postings, transactions, accounts and more.
-- If the first boolean is False, it's an inverse match.
-- Currently used by hledger-web, will likely replace FilterSpec at some point.
data Matcher = MatchAny                   -- ^ always match
             | MatchNone                  -- ^ never match
             | MatchOr [Matcher]          -- ^ match if any of these match
             | MatchAnd [Matcher]         -- ^ match if all of these match
             | MatchDesc Bool String      -- ^ match if description matches this regexp
             | MatchAcct Bool String      -- ^ match postings whose account matches this regexp
             | MatchDate Bool DateSpan    -- ^ match if actual date in this date span
             | MatchEDate Bool DateSpan   -- ^ match if effective date in this date span
             | MatchStatus Bool Bool      -- ^ match if cleared status has this value
             | MatchReal Bool Bool        -- ^ match if "realness" (involves a real non-virtual account ?) has this value
             | MatchEmpty Bool Bool       -- ^ match if "emptiness" (from the --empty command-line flag) has this value.
                                          --   Currently this means a posting with zero amount.
             | MatchDepth Bool Int        -- ^ match if account depth is less than or equal to this value
    deriving (Show, Eq)

-- | A query option changes a query's/report's behaviour and output in some way.

-- XXX could use regular CliOpts ?
data QueryOpt = QueryOptInAcctOnly AccountName  -- ^ show an account register focussed on this account
              | QueryOptInAcct AccountName      -- ^ as above but include sub-accounts in the account register
           -- | QueryOptCostBasis      -- ^ show amounts converted to cost where possible
           -- | QueryOptEffectiveDate  -- ^ show effective dates instead of actual dates
    deriving (Show, Eq)

-- | The account we are currently focussed on, if any, and whether subaccounts are included.
-- Just looks at the first query option.
inAccount :: [QueryOpt] -> Maybe (AccountName,Bool)
inAccount [] = Nothing
inAccount (QueryOptInAcctOnly a:_) = Just (a,False)
inAccount (QueryOptInAcct a:_) = Just (a,True)

-- | A matcher for the account(s) we are currently focussed on, if any.
-- Just looks at the first query option.
inAccountMatcher :: [QueryOpt] -> Maybe Matcher
inAccountMatcher [] = Nothing
inAccountMatcher (QueryOptInAcctOnly a:_) = Just $ MatchAcct True $ accountNameToAccountOnlyRegex a
inAccountMatcher (QueryOptInAcct a:_) = Just $ MatchAcct True $ accountNameToAccountRegex a

-- -- | A matcher restricting the account(s) to be shown in the sidebar, if any.
-- -- Just looks at the first query option.
-- showAccountMatcher :: [QueryOpt] -> Maybe Matcher
-- showAccountMatcher (QueryOptInAcctSubsOnly a:_) = Just $ MatchAcct True $ accountNameToAccountRegex a
-- showAccountMatcher _ = Nothing

-- | Convert a query expression containing zero or more space-separated
-- terms to a matcher and zero or more query options. A query term is either:
--
-- 1. a search criteria, used to match transactions. This is usually a prefixed pattern such as:
--    acct:REGEXP
--    date:PERIODEXP
--    not:desc:REGEXP
--
-- 2. a query option, which changes behaviour in some way. There is currently one of these:
--    inacct:FULLACCTNAME - should appear only once
--
-- Multiple search criteria are AND'ed together.
-- When a pattern contains spaces, it or the whole term should be enclosed in single or double quotes.
-- A reference date is required to interpret relative dates in period expressions.
--
parseQuery :: Day -> String -> (Matcher,[QueryOpt])
parseQuery d s = (m,qopts)
  where
    terms = words'' prefixes s
    (matchers, qopts) = partitionEithers $ map (parseMatcher d) terms
    m = case matchers of []      -> MatchAny
                         (m':[]) -> m'
                         ms      -> MatchAnd ms

-- keep synced with patterns below, excluding "not"
prefixes = map (++":") [
            "inacct","inacctonly",
            "desc","acct","date","edate","status","real","empty","depth"
           ]
defaultprefix = "acct"

-- | Parse a single query term as either a matcher or a query option.
parseMatcher :: Day -> String -> Either Matcher QueryOpt
parseMatcher _ ('i':'n':'a':'c':'c':'t':'o':'n':'l':'y':':':s) = Right $ QueryOptInAcctOnly s
parseMatcher _ ('i':'n':'a':'c':'c':'t':':':s) = Right $ QueryOptInAcct s
parseMatcher d ('n':'o':'t':':':s) = case parseMatcher d $ quoteIfSpaced s of
                                       Left m  -> Left $ negateMatcher m
                                       Right _ -> Left MatchAny -- not:somequeryoption will be ignored
parseMatcher _ ('d':'e':'s':'c':':':s) = Left $ MatchDesc True s
parseMatcher _ ('a':'c':'c':'t':':':s) = Left $ MatchAcct True s
parseMatcher d ('d':'a':'t':'e':':':s) =
        case parsePeriodExpr d s of Left _ -> Left MatchNone -- XXX should warn
                                    Right (_,span) -> Left $ MatchDate True span
parseMatcher d ('e':'d':'a':'t':'e':':':s) =
        case parsePeriodExpr d s of Left _ -> Left MatchNone -- XXX should warn
                                    Right (_,span) -> Left $ MatchEDate True span
parseMatcher _ ('s':'t':'a':'t':'u':'s':':':s) = Left $ MatchStatus True $ parseStatus s
parseMatcher _ ('r':'e':'a':'l':':':s) = Left $ MatchReal True $ parseBool s
parseMatcher _ ('e':'m':'p':'t':'y':':':s) = Left $ MatchEmpty True $ parseBool s
parseMatcher _ ('d':'e':'p':'t':'h':':':s) = Left $ MatchDepth True $ readDef 0 s
parseMatcher _ "" = Left $ MatchAny
parseMatcher d s = parseMatcher d $ defaultprefix++":"++s

-- | Parse the boolean value part of a "status:" matcher, allowing "*" as
-- another way to spell True, similar to the journal file format.
parseStatus :: String -> Bool
parseStatus s = s `elem` (truestrings ++ ["*"])

-- | Parse the boolean value part of a "status:" matcher. A true value can
-- be spelled as "1", "t" or "true".
parseBool :: String -> Bool
parseBool s = s `elem` truestrings

truestrings :: [String]
truestrings = ["1","t","true"]

-- | Quote-and-prefix-aware version of words - don't split on spaces which
-- are inside quotes, including quotes which may have one of the specified
-- prefixes in front, and maybe an additional not: prefix in front of that.
words'' :: [String] -> String -> [String]
words'' prefixes = fromparse . parsewith maybeprefixedquotedphrases -- XXX
    where
      maybeprefixedquotedphrases = choice' [prefixedQuotedPattern, quotedPattern, pattern] `sepBy` many1 spacenonewline
      prefixedQuotedPattern = do
        not' <- optionMaybe $ string "not:"
        prefix <- choice' $ map string prefixes
        p <- quotedPattern
        return $ fromMaybe "" not' ++ prefix ++ stripquotes p
      quotedPattern = do
        p <- between (oneOf "'\"") (oneOf "'\"") $ many $ noneOf "'\""
        return $ stripquotes p
      pattern = many (noneOf " \n\r\"")

-- -- | Parse the query string as a boolean tree of match patterns.
-- parseMatcher :: String -> Matcher
-- parseMatcher s = either (const (MatchAny)) id $ runParser matcher () "" $ lexmatcher s

-- lexmatcher :: String -> [String]
-- lexmatcher s = words' s

-- matcher :: GenParser String () Matcher
-- matcher = undefined

-- | Convert a match expression to its inverse.
negateMatcher :: Matcher -> Matcher
negateMatcher MatchAny                   = MatchNone
negateMatcher MatchNone                  = MatchAny
negateMatcher (MatchOr ms)               = MatchAnd $ map negateMatcher ms
negateMatcher (MatchAnd ms)              = MatchOr $ map negateMatcher ms
negateMatcher (MatchAcct sense arg)      = MatchAcct (not sense) arg
negateMatcher (MatchDesc sense arg)      = MatchDesc (not sense) arg
negateMatcher (MatchDate sense arg)      = MatchDate (not sense) arg
negateMatcher (MatchEDate sense arg)     = MatchEDate (not sense) arg
negateMatcher (MatchStatus sense arg)    = MatchStatus (not sense) arg
negateMatcher (MatchReal sense arg)      = MatchReal (not sense) arg
negateMatcher (MatchEmpty sense arg)     = MatchEmpty (not sense) arg
negateMatcher (MatchDepth sense arg)     = MatchDepth (not sense) arg

-- | Does the match expression match this posting ?
matchesPosting :: Matcher -> Posting -> Bool
matchesPosting (MatchAny) _ = True
matchesPosting (MatchNone) _ = False
matchesPosting (MatchOr ms) p = any (`matchesPosting` p) ms
matchesPosting (MatchAnd ms) p = all (`matchesPosting` p) ms
matchesPosting (MatchDesc True r) p = regexMatchesCI r $ maybe "" tdescription $ ptransaction p
matchesPosting (MatchDesc False r) p = not $ (MatchDesc True r) `matchesPosting` p
matchesPosting (MatchAcct True r) p = regexMatchesCI r $ paccount p
matchesPosting (MatchAcct False r) p = not $ (MatchAcct True r) `matchesPosting` p
matchesPosting (MatchDate True span) p =
    case d of Just d'  -> spanContainsDate span d'
              Nothing -> False
    where d = maybe Nothing (Just . tdate) $ ptransaction p
matchesPosting (MatchDate False span) p = not $ (MatchDate True span) `matchesPosting` p
matchesPosting (MatchEDate True span) p =
    case postingEffectiveDate p of Just d  -> spanContainsDate span d
                                   Nothing -> False
matchesPosting (MatchEDate False span) p = not $ (MatchEDate True span) `matchesPosting` p
matchesPosting (MatchStatus True v) p = v == postingCleared p
matchesPosting (MatchStatus False v) p = v /= postingCleared p
matchesPosting (MatchReal True v) p = v == isReal p
matchesPosting (MatchReal False v) p = v /= isReal p
matchesPosting (MatchEmpty True v) Posting{pamount=a} = v == isZeroMixedAmount a
matchesPosting (MatchEmpty False v) p = not $ (MatchEmpty True v) `matchesPosting` p
matchesPosting _ _ = False

-- | Does the match expression match this transaction ?
matchesTransaction :: Matcher -> Transaction -> Bool
matchesTransaction (MatchAny) _ = True
matchesTransaction (MatchNone) _ = False
matchesTransaction (MatchOr ms) t = any (`matchesTransaction` t) ms
matchesTransaction (MatchAnd ms) t = all (`matchesTransaction` t) ms
matchesTransaction (MatchDesc True r) t = regexMatchesCI r $ tdescription t
matchesTransaction (MatchDesc False r) t = not $ (MatchDesc True r) `matchesTransaction` t
matchesTransaction m@(MatchAcct True _) t = any (m `matchesPosting`) $ tpostings t
matchesTransaction (MatchAcct False r) t = not $ (MatchAcct True r) `matchesTransaction` t
matchesTransaction (MatchDate True span) t = spanContainsDate span $ tdate t
matchesTransaction (MatchDate False span) t = not $ (MatchDate True span) `matchesTransaction` t
matchesTransaction (MatchEDate True span) t = spanContainsDate span $ transactionEffectiveDate t
matchesTransaction (MatchEDate False span) t = not $ (MatchEDate True span) `matchesTransaction` t
matchesTransaction (MatchStatus True v) t = v == tstatus t
matchesTransaction (MatchStatus False v) t = v /= tstatus t
matchesTransaction (MatchReal True v) t = v == hasRealPostings t
matchesTransaction (MatchReal False v) t = v /= hasRealPostings t
matchesTransaction _ _ = False

postingEffectiveDate :: Posting -> Maybe Day
postingEffectiveDate p = maybe Nothing (Just . transactionEffectiveDate) $ ptransaction p

transactionEffectiveDate :: Transaction -> Day
transactionEffectiveDate t = case teffectivedate t of Just d  -> d
                                                      Nothing -> tdate t

-- | Does the match expression match this account ?
-- A matching in: clause is also considered a match.
matchesAccount :: Matcher -> AccountName -> Bool
matchesAccount (MatchAny) _ = True
matchesAccount (MatchNone) _ = False
matchesAccount (MatchOr ms) a = any (`matchesAccount` a) ms
matchesAccount (MatchAnd ms) a = all (`matchesAccount` a) ms
matchesAccount (MatchAcct True r) a = regexMatchesCI r a
matchesAccount (MatchAcct False r) a = not $ (MatchAcct True r) `matchesAccount` a
matchesAccount _ _ = False

-- | What start date does this matcher specify, if any ?
-- If the matcher is an OR expression, returns the earliest of the alternatives.
-- When the flag is true, look for a starting effective date instead.
matcherStartDate :: Bool -> Matcher -> Maybe Day
matcherStartDate effective (MatchOr ms) = earliestMaybeDate $ map (matcherStartDate effective) ms
matcherStartDate effective (MatchAnd ms) = latestMaybeDate $ map (matcherStartDate effective) ms
matcherStartDate False (MatchDate True (DateSpan (Just d) _)) = Just d
matcherStartDate True (MatchEDate True (DateSpan (Just d) _)) = Just d
matcherStartDate _ _ = Nothing

-- | Does this matcher specify a start date and nothing else (that would
-- filter postings prior to the date) ?
-- When the flag is true, look for a starting effective date instead.
matcherIsStartDateOnly :: Bool -> Matcher -> Bool
matcherIsStartDateOnly _ MatchAny = False
matcherIsStartDateOnly _ MatchNone = False
matcherIsStartDateOnly effective (MatchOr ms) = and $ map (matcherIsStartDateOnly effective) ms
matcherIsStartDateOnly effective (MatchAnd ms) = and $ map (matcherIsStartDateOnly effective) ms
matcherIsStartDateOnly False (MatchDate _ (DateSpan (Just _) _)) = True
matcherIsStartDateOnly True (MatchEDate _ (DateSpan (Just _) _)) = True
matcherIsStartDateOnly _ _ = False

-- | Does this matcher match everything ?
matcherIsNull MatchAny = True
matcherIsNull (MatchAnd []) = True
matcherIsNull _ = False

-- | What is the earliest of these dates, where Nothing is earliest ?
earliestMaybeDate :: [Maybe Day] -> Maybe Day
earliestMaybeDate = headDef Nothing . sortBy compareMaybeDates

-- | What is the latest of these dates, where Nothing is earliest ?
latestMaybeDate :: [Maybe Day] -> Maybe Day
latestMaybeDate = headDef Nothing . sortBy (flip compareMaybeDates)

-- | Compare two maybe dates, Nothing is earliest.
compareMaybeDates :: Maybe Day -> Maybe Day -> Ordering
compareMaybeDates Nothing Nothing = EQ
compareMaybeDates Nothing (Just _) = LT
compareMaybeDates (Just _) Nothing = GT
compareMaybeDates (Just a) (Just b) = compare a b

tests_Hledger_Data_Matching :: Test
tests_Hledger_Data_Matching = TestList
 [

  "parseQuery" ~: do
    let d = parsedate "2011/1/1"
    parseQuery d "a" `is` (MatchAcct True "a", [])
    parseQuery d "acct:a" `is` (MatchAcct True "a", [])
    parseQuery d "acct:a desc:b" `is` (MatchAnd [MatchAcct True "a", MatchDesc True "b"], [])
    parseQuery d "\"acct:expenses:autres d\233penses\"" `is` (MatchAcct True "expenses:autres d\233penses", [])
    parseQuery d "not:desc:'a b'" `is` (MatchDesc False "a b", [])

    parseQuery d "inacct:a desc:b" `is` (MatchDesc True "b", [QueryOptInAcct "b"])
    parseQuery d "inacct:a inacct:b" `is` (MatchAny, [QueryOptInAcct "a"])

    parseQuery d "status:1" `is` (MatchStatus True True, [])
    parseQuery d "status:0" `is` (MatchStatus True False, [])
    parseQuery d "status:" `is` (MatchStatus True False, [])
    parseQuery d "real:1" `is` (MatchReal True True, [])

  ,"matchesAccount" ~: do
    assertBool "positive acct match" $ matchesAccount (MatchAcct True "b:c") "a:bb:c:d"
    -- assertBool "acct should match at beginning" $ not $ matchesAccount (MatchAcct True "a:b") "c:a:b"

  ,"matchesPosting" ~: do
    -- matching posting status..
    assertBool "positive match on true posting status"  $
                   (MatchStatus True  True)  `matchesPosting` nullposting{pstatus=True}
    assertBool "negative match on true posting status"  $
               not $ (MatchStatus False True)  `matchesPosting` nullposting{pstatus=True}
    assertBool "positive match on false posting status" $
                   (MatchStatus True  False) `matchesPosting` nullposting{pstatus=False}
    assertBool "negative match on false posting status" $
               not $ (MatchStatus False False) `matchesPosting` nullposting{pstatus=False}
    assertBool "positive match on true posting status acquired from transaction" $
                   (MatchStatus True  True) `matchesPosting` nullposting{pstatus=False,ptransaction=Just nulltransaction{tstatus=True}}
    assertBool "real:1 on real posting" $ (MatchReal True True) `matchesPosting` nullposting{ptype=RegularPosting}
    assertBool "real:1 on virtual posting fails" $ not $ (MatchReal True True) `matchesPosting` nullposting{ptype=VirtualPosting}
    assertBool "real:1 on balanced virtual posting fails" $ not $ (MatchReal True True) `matchesPosting` nullposting{ptype=BalancedVirtualPosting}

 ]
