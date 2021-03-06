{-# LANGUAGE OverloadedStrings #-}
{- |
Module: Data.FCA
Maintainer: Thomas Sutton

This module implements an algorithm to perform Formal Concept Analysis on a
concept. The algorithm is that described in /Introduction to Lattices and Order/
(second edition) by B. A. Davey and H. A. Priestly.

This implementation is rather hackish and probably quite inefficient but
helped me (rather: is helping me) to understand to topic.

-}
module Data.FCA where

import           Data.Function
import           Data.Functor
import           Data.List                   (intersperse, minimumBy, nub,
                                              sort, sortBy)
import           Data.Map.Strict             (Map)
import qualified Data.Map.Strict             as M
import           Data.Maybe
import           Data.Monoid
import           Data.Set                    (Set)
import qualified Data.Set                    as S
import           Data.Text.Lazy              (Text)
import qualified Data.Text.Lazy              as T
import           Data.Text.Lazy.Builder
import           Data.Text.Lazy.Builder.Int
import           Data.Vector                 (Vector)
import qualified Data.Vector                 as V
import qualified Data.Vector.Algorithms.Heap as V

-- * Data types

-- | We'll just use integers to identify attributes.
type AttrId = Int

-- | Similarly for objects.
type ObjId = Int

-- | Names of objects and attributes can be text.
type Name = Text

-- | An attribute is an ID together with a set of objects which have the
-- attribute.
type Attribute = (AttrId, Set ObjId)

-- | A Context is an incidence matrix between objects and attributes. It's
-- attribute major.
type Context = Vector Attribute

-- | An AETable is the internal datastructure of the algorithm.
type AETable = Vector AERow

-- | An AERow represents a point in the concept lattice with the given
-- attributes and the extent.
--
-- These values are not, themselves, necessarily concepts; they merely
-- represent them in the lattice.
type AERow = (Set AttrId, Set ObjId)

-- | A 'Frame' couples a 'Context' together with the maps to translate object
-- and attribute IDs back to input strings.
data Frame = Frame
    { frameContext    :: Context
    , frameObjects    :: Map ObjId Name
    , frameAttributes :: Map AttrId Name
    }
  deriving (Show, Eq)

-- * Internal

-- | Build maps to translate unique 'Text' values to and from 'Int's.
toTranslation :: Vector Text -> (Map Int Text, Map Text Int)
toTranslation v =
    let l = zip [0..] $ sort $ nub $ V.toList v
        it = foldl (\m (i,n)-> M.insert i n m) M.empty l
        ti = foldl (\m (i,n)-> M.insert n i m) M.empty l
    in (it, ti)

-- * Input handling

-- $ An input data set can be provided in three different formats:
--
-- * entity-attribute pairs are the "native" format;
--
-- * entity-attribute-value triples are converted to entity-attribute by
-- concatenating the attribute and value; and
--
-- * tabular data describes an adjacency matrix between entities (rows) and
-- attributes (columns).

-- | Parse entity-attribute formatted data into a 'Frame'.
parseEA :: Vector (Text, Text) -> Frame
parseEA csv =
    let (omap, romap) = toTranslation $ V.map fst csv
        (amap, ramap) = toTranslation $ V.map snd csv
        fn (o,a) = M.alter (Just . maybe (S.singleton o) (S.insert o)) a
        ctx' = V.foldr fn M.empty csv
        ctx = V.fromList $ sort $ map (\(k,v) -> (fromJust (M.lookup k ramap), S.map (fromJust . flip M.lookup romap) v )) $ M.toList ctx'
    in Frame ctx omap amap

-- | Parse entity-attribute-value formated data into a 'Frame'.
parseEAV :: Vector (Name, Name, Name) -> Frame
parseEAV csv =
    let csv' = V.map (\(n,a,v) -> (n, a <> v)) csv
    in parseEA csv'

-- | Parse tabular formatted data into a 'Frame'.
--
-- This function converts a vector of object-records into a context and a pair
-- of maps which can be used to recover the human-readable names for output.
--
-- Note that this function assumes that the input data is rectangular.
parseTabular :: Vector (Vector Name) -> Frame
parseTabular csv =
    let attrs = V.toList . V.tail . V.head $ csv
        values = concatMap (convert attrs) . V.toList . V.tail $ csv
    in parseEA . V.fromList $ values
  where
    convert :: [Text] -> Vector Text -> [(Text, Text)]
    convert attrs object =
        let obj   = V.head object
            vals  = V.toList . V.tail $ object
            pairs = map extract . filter (not . T.null . thrd) $ zip3 (repeat obj) attrs vals
        in pairs
    thrd :: (a,b,c) -> c
    thrd (_,_,c) = c
    extract :: (a,b,c) -> (a,b)
    extract (a,b,_) = (a,b)

-- * Algorithms

-- $ These functions implement the key details of the concept lattice
-- construction algorithm.

-- | Construct the attribute-extent table of a context.
buildAETable :: Context -> AETable
buildAETable ctx = let g = V.foldl (\s v-> S.union s $ snd v) S.empty ctx
                       t = snd $ work ctx $ V.singleton (S.empty, g)
                   in t V.++ V.singleton (S.empty, S.empty)
  where
    work :: Context -> AETable -> (Context, AETable)
    work ctx table = maybe (ctx, table)
                     (\(a, ctx') -> work ctx' $ insertAttr a table)
                     (chooseMax ctx)

-- | Construct a lattice from an attribute-extent table and generate a `dot`
-- graph describing it.
--
-- Points in the generated graph are labelled with names from the input data.
generateGraph
    :: AETable          -- ^ Context lattice table.
    -> Map ObjId Name   -- ^ Map from object ID to name.
    -> Map AttrId Name  -- ^ Map from attribute ID to name.
    -> Text
generateGraph table omap amap =
  let list   = zip [0..] $ V.toList table
      list'  = zip [0..] $ V.toList $ restrictObjectLabels table
  in toLazyText $ mconcat [ fromText "digraph {\n\trankdir=BT;\n\tfontsize=10.0;\n\tpad=0.25;\n\tnode[shape=\"circle\",width=\"0.08\",labelloc=t];\n\tedge[arrowhead=none];\n\n"
                          , mconcat $ map graphNode list'
                          , mconcat $ map (graphEdges list) list
                          , fromText "}\n"
                          ]
  where
    -- | Generate a @dot@ fragment for the node.
    graphNode (i, (as, os)) =
        let attrns = map (amap M.!) $ S.toList as
            objns = map (omap M.!) $ S.toList os
            label = fromText "xlabel=\"" <>
                    (mconcat . intersperse (fromText " ") $ map fromLazyText $ attrns ++ objns) <>
                    fromText "\""
        in mconcat [ fromText "\tc" , decimal i
                   , fromText " [label=\"\","
                   , label
                   , fromText " ];\n\n"
                   ]
    -- | Generate a @dot@ fragment for the edges of a node.
    graphEdges list (i, (as, os)) =
        let t = True
            targets = covering os $ take i list
            e i j = mconcat [ fromText "\tc", decimal i, fromText " -> c", decimal j, fromText ";\n"]
        in mconcat [ fromText "\t# Edges for c"
                   , decimal i
                   , fromText "\n"
                   , mconcat $ map (e i . fst) targets
                   ]
    -- | Find nodes which cover another.
    covering :: Set Int
             -> [(Int, (Set Int, Set Int))]
             -> [(Int, (Set Int, Set Int))]
    covering s ss =
        let candidates = filter (localSubsetOf (1,(S.empty,s))) ss
            cover = filter (\c -> not $ any (`localSubsetOf` c) candidates) candidates
        in cover
      where
        localSubsetOf (_,(_,s)) (_,(_,t)) = s `S.isProperSubsetOf` t

-- * Utilities

-- | Select the maximal attribute in the context.
--
-- Here, maximal means is not a proper subset of any other element.
chooseMax :: Context -> Maybe (Attribute, Context)
chooseMax ctx = flip vselect ctx <$> V.findIndex (f ctx) ctx
  where
    f ctx a = isNothing $
              V.findIndex (\b-> snd a `S.isProperSubsetOf` snd b) ctx

-- | Filter the labels in a table such that nodes are mentioned only in the
-- smallest extent which contains them.
restrictObjectLabels table =
    let es = V.foldl (flip S.insert) S.empty $ V.map snd table
        os = S.foldl S.union S.empty es
        om = S.foldl (\m o -> M.insert o (smallestWith o es) m)
             M.empty
             os
    in V.map (\(as,os) -> (as, filterSetByMap os om)) table

-- | Insert a new attribute and it's extent into the table.
--
-- If the extent is already present, the existing row will be labelled with the
-- additional attribute; otherwise, a new row will be added.
insertAttr :: Attribute -> AETable -> AETable
insertAttr (attr, ext) table =
  let t = table
      i = V.findIndex (\r -> ext == snd r) table
  in case i of
    -- Add the label to the existing row.
    Just j -> labelAttr j attr table
    -- Add a new row to the table.
    Nothing -> addIntersects attr ext $ extendTable attr ext table
  where
    extendTable :: AttrId -> Set ObjId -> AETable -> AETable
    extendTable a e t = V.snoc t (S.singleton a, e)
    labelAttr j a t = let (attr, extent) = t V.! j
                          r = (S.insert a attr, extent)
                      in table V.// [(j, r)]
    addIntersects :: AttrId -> Set ObjId -> AETable -> AETable
    addIntersects a e t = let current = V.map snd t
                              new = V.filter (\s -> (not . S.null $ s) && V.notElem s current) $ V.map (S.intersection e) current
                          in (t V.++) $ V.map (\x -> (S.empty, x)) new

-- | Find the smallest set containing an element.
--
-- This is partial.
smallestWith :: Ord e => e -> Set (Set e) -> Set e
smallestWith e ss =
    let candidates = S.filter (S.member e) ss
        smallest = minimumBy (compare `on` S.size) $ S.toList candidates
    in smallest

-- | Filter the elements @e@ of @s@ by whether or not @m@ maps @e@ to @s@.
--
-- That is, the map @m@ should take @e@ to @s@ is @e@ is a valid member of @s@.
filterSetByMap :: Ord i =>
                  Set i -- ^ The set to filter
               -> Map i (Set i) -- ^ The map
               -> Set i
filterSetByMap s m = S.filter (\e -> (m M.! e) == s) s

-- | Extract and remove the element with the specified index from a vector.
vselect :: Int -- ^ The index.
        -> Vector a -- ^ The vector.
        -> (a, Vector a) -- ^ The value and new vector.
vselect i v = (v V.! i , V.ifilter (\j _ -> i /= j) v)
