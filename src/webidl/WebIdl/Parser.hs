module WebIdl.Parser where

-- import WebIdl
import WebIdl.Ast
import WebIdl.Lex
import WebIdl.Helper

-- import GHC.Exts(sortWith)
import Data.Traversable
import Control.Applicative((<$>), (<*>), liftA2)
-- import Data.Maybe(fromMaybe)

import Text.Parsec.Char
import Text.Parsec.Combinator
import Text.Parsec.String
import Text.Parsec.Prim

{- |
$setup

-}

{-
TODO there is still many opportunities to better abstract over many things these parses do, for example:
- Things that goes after "=" (const, dictionary attributes, interface attributes - not callback, though)
- All top level definitions (interface, callback, dictionary etc) all share many common data
- Perhaps even implement an IDL parser based on these abstractions
-}

webIdl :: Parser WebIdl
webIdl = 
    let 
        process :: Parser [Definition]
        process = do 
            whites
            --skipMany (try $ lineComment >>> whites)
            defs <- many (interface <|> callback <|> typeDef <|> dictionary) <?> "Top level defitinion"
            --(defs ++) <$> process
            return defs
    in WebIdl <$> process


{- | 
>>> run interface "[Constructor]\n interface SELF : SUPER {}"
Interface "SELF" "Constructor" (Just "SUPER") []

TODO Think of a better way to test:

>>> runFile interface "interface-test1.webidl"
Interface "IFACE" "Constructor" (Just "SUPER") [Attribute "ATT_TYP1" "ATT1" True False,Attribute "ATT_TYP2" "ATT2" True True,Attribute "ATT_TYP3" "ATT3" False False,Operation "OP1" "RET_TYP1" [FormalArg "unsigned long" "ARG1" Nothing,FormalArg "unsigned long" "ARG2" Nothing],Operation "OP2" "void" [FormalArg "ARG_TYP3" "ARG3" Nothing,FormalArg "unsigned long" "ARG4" (Just (Number "2"))]]
-}
interface :: Parser Definition 
interface = do
    eatt <- extendedAtt
    stringTok "interface"
    i <- identifier
    inherits <- inheriting 
    members <- inBraces $ 
        many (try attribute 
            <|> try operation 
            <|> try constVal
            <|> try getter
            <|> try setter
            <|> try creator
            <|> try deleter)
    endl
    (return $ Interface i inherits members eatt) <?> "Interface definition"

{- |
    TODO: any thing after ":" can be a type parsed by "parseType", this is wrong. 
-}
inheriting :: Parser (Maybe Type)
inheriting = do 
        optional $ charTok ':'
        typ <- optionMaybe parseType
        return typ

{- |
>>> run typeDef "typedef unsigned long  GLenum;"
TypeDef "GLenum" (Type "unsigned long" False False)
-}
typeDef :: Parser Definition
typeDef = do 
    stringTok "typedef"
    eatt <- extendedAtt
    typ <- parseType
    i <- identifier
    endl
    (return $ TypeDef i typ eatt) <?> "typedef definition"

{- | 
>>> run callback "callback DecodeSuccessCallback = void (AudioBuffer decodedData);"
Callback "DecodeSuccessCallback" "" (CallbackDecl "void" [FormalArg "AudioBuffer" "decodedData" Nothing])
-}
callback :: Parser Definition
callback = do 
    eatt <- extendedAtt
    stringTok "callback"
    ident <- identifier
    charTok '='
    typ <- parseType
    args <- formalArgs
    endl
    (return $ Callback ident (CallbackDef typ args) eatt) <?> "callback definition"

dictionary :: Parser Definition
dictionary = do
    eatt <- extendedAtt
    stringTok "dictionary"
    ident <- identifier
    inherits <- inheriting
    members <- inBraces $ many dictAttribute
    endl
    (return $ Dictionary ident inherits members eatt) <?> "dictionary def"

dictAttribute :: Parser DictAttribute
dictAttribute = do
    eatt <- extendedAtt
    typ <- parseType
    i <- identifier
    lit <- optionMaybe (charTok '=' >>> value)
    endl
    return $ DictAttribute i typ lit eatt


{- |
>>> run operation "AudioBuffer createBuffer(unsigned long numberOfChannels, unsigned long length, float sampleRate);"
Operation "createBuffer" "AudioBuffer" [FormalArg "unsigned long" "numberOfChannels" Nothing,FormalArg "unsigned long" "length" Nothing,FormalArg "float" "sampleRate" Nothing]
-}
operation :: Parser IMember
operation = do
    eatt <- extendedAtt
    typ <- parseType
    ident <- identifier
    args <- formalArgs
    endl
    return $ Operation ident typ args eatt


formalArgs :: Parser [FormalArg]
formalArgs = do 
    args <- inParens $ sepBy formalArg $ charTok ','
    return args

{- |
>>> run formalArg "AudioBuffer decodedData"
FormalArg "AudioBuffer" "decodedData" Nothing
>>> run formalArg "optional Bleh bufferSize = 0"
FormalArg "Bleh" "bufferSize" (Just (Number "0"))
>>> run formalArg "optional unsigned long bufferSize = \"aaa\""
FormalArg "unsigned long" "bufferSize" (Just (Str "aaa"))
-}
formalArg :: Parser FormalArg
formalArg = do
    eatt <- extendedAtt
    opt <- optionMaybe $ stringTok "optional" --  opt :: Maybe String
    typ <- parseType <?> "type of formal argument"
    i <- identifier <?> "identifier of formal argument"
    --let deflt = traverse (\_ -> do try $ charTok '='; val <- value; return val) opt
    --df <- deflt <?> "default value"
    df <- (id =<< ) <$> (const $ (optionMaybe $ charTok '=' >>> value)) `traverse` opt
    return $ FormalArg i typ (Optional $ justTrue opt) df eatt

{- |
>>> run attribute "readonly attribute TYPE NAME;"
Attribute "TYPE" "NAME" True False
>>> run attribute "inherit readonly attribute TYPE NAME;"
Attribute "TYPE" "NAME" True True
-}
attribute :: Parser IMember
attribute = do
    eatt <- extendedAtt
    inherit <- optionMaybe $ stringTok "inherit"
    readonly <- optionMaybe $ stringTok "readonly"
    stringTok "attribute"
    i <- identifier
    typ <- parseType
    endl
    return $ Attribute i typ ((ReadOnly . justTrue) readonly) ((Inherit . justTrue) inherit) eatt

getter :: Parser IMember
getter = special1 "getter" Getter

deleter :: Parser IMember
deleter = special1 "deleter" Deleter

setter :: Parser IMember
setter = special2 "setter" Setter

creator :: Parser IMember
creator = special2 "creator" Creator

    
special1 tok cons = do
    eatt <- extendedAtt
    stringTok tok
    typ <- parseType
    i   <- optionMaybe identifier
    arg <- inParens formalArg
    endl
    return $ cons i typ arg

special2 tok cons = do
    eatt <- extendedAtt
    stringTok tok
    typ <- parseType
    i   <- optionMaybe identifier
    (arg0, arg1) <- inParens $ (liftA2 (,)) formalArg  formalArg
    endl
    return $ cons i typ arg0 arg1

extendedAtt :: Parser ExtendedAtt
extendedAtt = -- TODO: skipWhites is really needed here? should it be before or after `option`?
    ExtendedAtt <$> 
    (option [] $ skipWhites $ inBrackets $ sepBy (many $ noneOf ",]") (charTok ',')) 

{- |
>>> run constVal "const TYPE NAME = 0x0000;"
Const "NAME" (Type "TYPE" False False) (Hex "0000")
-}
constVal :: Parser IMember 
constVal = do 
    eatt <- extendedAtt
    stringTok "const"
    typ <- parseType
    i <- identifier
    charTok '='
    lit <- value
    endl
    (return $ Const i typ lit eatt) <?> "const definition"


{- TODO 
  Still misses:
  - sequence<>
  - any
  - object
  - union types
    
  http://www.w3.org/TR/WebIDL/#prod-Type

  TODO DOCTESTS
-}
parseType :: Parser Type
parseType = do
    -- TODO sequence<T> where T can be another type, write now I am ignoring the recursivity
    -- also, T itself can be/have "[]" "?", this is also currently ignored
    sequ <- optionMaybe $ try $ stringTok "sequence<" -- :: Parser Maybe String
    i <- (Ident <$> try parseCTypes) <|> identifier 
    (const $ stringTok ">") `traverse` sequ
    array <- optionMaybe $ string "[]"
    nullable <- optionMaybe $ char '?'
    whites
    (return $ 
        Type i ((Nullable . justTrue) nullable) ((Array . justTrue) array) ((Sequence . justTrue) sequ)) <?> "type declaration"

identifier :: Parser Ident
identifier = Ident <$> (identTok <?> "identifier")

