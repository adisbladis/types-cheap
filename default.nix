/*

A tiny & fast composable type system for Nix, in Nix.

Named after the [little penguin](https://www.doc.govt.nz/nature/native-animals/birds/birds-a-z/penguins/little-penguin-korora/).

# Features

- Types
  - Primitive types (`string`, `int`, etc)
  - Polymorphic types (`union`, `attrsOf`, etc)
  - Struct types

# Basic usage

- Verification

Basic verification is done with the type function `verify`:
``` nix
{ korora }:
let
  t = korora.string;

  value = 1;

  # Error contains the string "Expected type 'string' but value '1' is of type 'int'"
  error = t.verify 1;

in if error != null then throw error else value
```
Errors are returned as a string.
On success `null` is returned.

- Checking (assertions)

For convenience you can also check a value on-the-fly:
``` nix
{ korora }:
let
  t = korora.string;

  # Same error as previous example, but `check` throws.
  value = t.check 1;

in value
```

On error `check` throws. On success it returns the value that was passed in.

# Examples
For usage example see [tests.nix](./tests.nix).

# Reference
*/
{ lib }:
let
  inherit (builtins) typeOf isString isFunction isAttrs isList all attrValues concatStringsSep any isInt isFloat isBool attrNames elem listToAttrs foldl';
  inherit (lib) findFirst nameValuePair concatMapStringsSep escapeShellArg makeOverridable optional;

  isTypeDef = t: isAttrs t && t ? name && isString t.name && t ? verify && isFunction t.verify;

  toPretty = lib.generators.toPretty { indent = "    "; };

  typeError = name: v: "Expected type '${name}' but value '${toPretty v}' is of type '${typeOf v}'";

  # Builtin primitive checkers return a bool for indicating errors but we return option<str>
  wrapBoolVerify = name: verify: v: if verify v then null else typeError name v;

  # Wrap builtins.all to return option<str>, with string on error.
  all' = func: list: if all (v: func v == null) list then null else (
    # If an error was found, run the checks again to find the first error to return.
    func (findFirst (v: func v != null) (abort "This should never ever happen") list)
  );

  addErrorContext = context: error: if error == null then null else "${context}: ${error}";

in
lib.fix(self: {
  # Utility functions

  /*
  Declare a custom type using a bool function.
  */
  typedef =
    # Name of the type as a string
    name:
    # Verification function returning a bool.
    verify:
    assert isString name; assert isFunction verify; self.typedef' name (wrapBoolVerify name verify);

  /*
  Declare a custom type using an option<str> function.
  */
  typedef' =
    # Name of the type as a string
    name:
    # Verification function returning null on success & a string with error message on error.
    verify:
    assert isString name; assert isFunction verify; {
      inherit name verify;
      check = v: if verify v == null then v else throw (verify v);
    };

  # Primitive types

  /*
  String
  */
  string = self.typedef "string" isString;

  /*
  Type alias for string
  */
  str = self.string;

  /*
  Any
  */
  any = self.typedef' "any" (_: null);

  /*
  Int
  */
  int = self.typedef "int" isInt;

  /*
  Single precision floating point
  */
  float = self.typedef "float" isFloat;

  /*
  Either an int or a float
  */
  number = self.typedef "number" (v: isInt v || isFloat v);

  /*
  Bool
  */
  bool = self.typedef "bool" isBool;

  /*
  Attribute with undefined attribute types
  */
  attrs = self.typedef "attrs" isAttrs;

  /*
  Attribute with undefined element types
  */
  list = self.typedef "list" isList;

  /*
  Function
  */
  function = self.typedef "function" isFunction;

  # Polymorphic types

  /*
  Option<t>
  */
  option =
    # Null or t
    t:
    assert isTypeDef t; let
      name = "option<${t.name}>";
      inherit (t) verify;
      errorContext = "in ${name}";
    in self.typedef' name (v: if v == null then null else addErrorContext errorContext (verify v));

  /*
  listOf<t>
  */
  listOf =
    # Element type
    t: assert isTypeDef t; let
      name = "listOf<${t.name}>";
      inherit (t) verify;
      errorContext = "in ${name} element";
    in self.typedef' name (v: if ! isList v then typeError name v else addErrorContext errorContext (all' verify v));

  /*
  listOf<t>
  */
  attrsOf =
    # Attribute value type
    t: assert isTypeDef t; let
      name = "attrsOf<${t.name}>";
      inherit (t) verify;
      errorContext = "in ${name} value";
    in self.typedef' name (v: if ! isAttrs v then typeError name v else addErrorContext errorContext (all' verify (attrValues v)));

  /*
  union<types...>
  */
  union =
    # Any of listOf<t>
    types: assert isList types; assert all isTypeDef types; let
      name = "union<${concatStringsSep "," (map (t: t.name) types)}>";
      funcs = map (t: t.verify) types;
    in self.typedef name (v: any (func: func v == null) funcs);

  /*
  struct<name, members...>

  #### Features

  - Totality

  By default, all attribute names must be present in a struct. It is possible to override this by specifying _totality_. Here is how to do this:
  ``` nix
  (korora.struct "myStruct" {
    foo = types.string;
  }).override { total = false; }
  ```

  This means that a `myStruct` struct can have any of the keys omitted. Thus these are valid:
  ``` nix
  let
    s1 = { };
    s2 = { foo = "bar"; }
  in ...
  ```

  - Unknown attribute names

  By default, unknown attribute names are allowed.

  It is possible to override this by specifying `unknown`.
  ``` nix
  (korora.struct "myStruct" {
    foo = types.string;
  }).override { unknown = false; }
  ```

  This means that
  ``` nix
  {
    foo = "bar";
    baz = "hello";
  }
  ```
  is normally valid, but not when `unknown` is set to `false`.

  Because Nix lacks primitive operations to iterative over attribute sets without
  allocation this function allocates one intermediate attribute set per struct verification.

  - Custom invariants

  Custom struct verification functions can be added as such:
  ``` nix
  (types.struct "testStruct2" {
    x = types.int;
    y = types.int;
  }).override {
    extra = [
      (v: if v.x + v.y == 2 then "VERBOTEN" else null)
    ];
  };
  ```

  #### Function signature
  */
  struct =
    # Name of struct type as a string
    name:
    # Attribute set of type definitions.
    members:
    assert isAttrs members; assert all isTypeDef (attrValues members); let
      names = attrNames members;
      verifiers = listToAttrs (map (attr: nameValuePair attr members.${attr}.verify) names);
      errorContext = "in struct '${name}'";

      joinStr = concatMapStringsSep ", " escapeShellArg;
      expectedAttrsStr = joinStr names;

    in (makeOverridable ({
      total ? true
      , unknown ? true
      , extra ? null
    }:
    assert isBool total;
    assert isBool unknown;
    assert extra != null -> isFunction extra;
    let
      optionalFuncs =
        optional (!unknown) (v: if removeAttrs v names == { } then null else "keys [${joinStr (attrNames (removeAttrs v names))}] are unrecognized, expected keys are [${expectedAttrsStr}]")
        ++ optional (extra != null) extra;

      verify = foldl' (acc: func: v: if acc v != null then acc v else func v) (v: all' (
        attr:
        if v ? ${attr} then addErrorContext "in member '${attr}'" (verifiers.${attr} v.${attr})
        else if total then "missing member '${attr}'"
        else null
      ) names) optionalFuncs;

    in self.typedef' name (
      v: addErrorContext errorContext (
        if ! isAttrs v then typeError name v
        else verify v
      )
    ))) {};

  /*
  enum<name, elems...>
  */
  enum =
    # Name of enum type as a string
    name:
    # List of allowable enum members
    elems:
    assert isList elems; self.typedef' name (v: if elem v elems then null else "'${toPretty v}' is not a member of enum '${name}'");
})