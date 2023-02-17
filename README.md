# parse-full-api-dump

Simple Lune Script to Parse the Recently Discovered Roblox "Full-API-Dump.json" (Demonstration)

Sample output provided in the [gen](gen) directory.

___

## Basic Usage

* Install the [Lune Runtime CLI](https://github.com/filiptibell). (It's in this repo's [aftman.toml](aftman.toml) aswell!)
* Run "`lune parse members`", and by default, a `Members.lua` will be output in the [`gen`](gen) directory. You can also supply a `path` argument.
* profit??

### Commands

This was made as a *very* simple demonstration for this, I won't be making this too complex at all. File paths can be labeled `.lua`, `.luau`, `.json`, or `.json5`.

* `lune parse members <path?:Members.lua>`
* `lune parse props <respect_serialization_tags?:false> <path:?Properties.lua>`
