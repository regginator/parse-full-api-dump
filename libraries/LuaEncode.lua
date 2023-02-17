-- LuaEncode - Optimal Serialization of Lua Tables in Native Luau/Lua 5.1+
-- Copyright (c) 2022-2023 Reggie <reggie@latte.to> | MIT License
-- https://github.com/regginator/LuaEncode

local Type = typeof or type -- For custom Roblox engine data-type support via `typeof`, if it exists

-- For num checks
local PositiveInf = math.huge
local NegativeInf = -math.huge

-- Lua 5.1 doesn't have table.find
local FindInTable = table.find or function(inputTable, valueToFind) -- Ignoring the `init` arg, unneeded for us
    for Key, Value in ipairs(inputTable) do
        if Value == valueToFind then
            return Key -- Return the key idx
        end
    end
end

-- Simple function for directly checking the type on values, with their input, variable name,
-- and desired type name(s) to check
local function CheckType(inputData, dataName, ...)
    local DesiredTypes = {...}
    local InputDataType = Type(inputData)

    if not FindInTable(DesiredTypes, InputDataType) then
        error(string.format(
            "LuaEncode: Incorrect type for `%s`: `%s` expected, got `%s`",
            dataName,
            table.concat(DesiredTypes, ", "), -- For if multiple types are accepted
            InputDataType
        ), 0)
    end

    return inputData -- Return back input directly
end

-- Shallow clone function defaulting to `table.clone()` (only Luau), or manually
-- doing so for Lua 5.1+
local ShallowClone = table.clone or function(inputTable)
    local ClonedTable = {}

    for Key, Value in next, inputTable do
        ClonedTable[Key] = Value
    end

    return ClonedTable
end

-- This re-serializes a string back into Lua, for the interpreter
-- AND humans to read. This fixes `string.format("%q")` only outputting
-- in system encoding, instead of explicit Lua byte escapes
local SerializeString do
    -- These are control characters to be encoded in a certain way in Lua
    -- rather than just a byte escape (e.g. "\n" -> "\10")
    local SpecialCharacters = {
        -- Since the string is being wrapped with double quotes,
        -- we don't need to escape single quotes
        ["\""] = "\\\"", -- Double-Quote
        ["\\"] = "\\\\", -- (Literal) Backslash
        -- Special ASCII control char codes
        ["\a"] = "\\a", -- Bell; ASCII #7
        ["\b"] = "\\b", -- Backspace; ASCII #8
        ["\t"] = "\\t", -- Horizontal-Tab; ASCII #9
        ["\n"] = "\\n", -- Newline; ASCII #10
        ["\v"] = "\\v", -- Vertical-Tab; ASCII #11
        ["\f"] = "\\f", -- Form-Feed; ASCII #12
        ["\r"] = "\\r", -- Carriage-Return; ASCII #13
    }

    -- We need to assign all extra normal byte escapes for runtime optimization
    -- ASCII #s 32-126 include all printable characters that AREN'T
    -- in the extended ASCII list, aside from #127, `DEL`. This
    -- hits the signed 8-bit integer limit
    for Index = 0, 255 do
        local Character = string.char(Index)

        if not SpecialCharacters[Character] and (Index < 32 or Index > 126) then
            SpecialCharacters[Character] = "\\" .. Index
        end
    end

    function SerializeString(inputString)
        -- Replace all null bytes, ctrl chars, dbl quotes, literal backslashes,
        -- and bytes 0-31 and 127-255 with their respecive escapes
        -- FYI; We can't do "\0-\31" in Lua 5.1 (Only Luau/Lua 5.2+) due to an embedded zeros in pattern
        -- issue. See: https://stackoverflow.com/a/22962409
        return "\"" .. string.gsub(inputString, "[\"\\%z\1-\31\127-\255]", SpecialCharacters) .. "\""
    end
end

-- VERY simple function to get if an object is a service, used in instance path eval
local function IsService(object)
    local FindServiceSuccess, ServiceObject = pcall(game.FindService, game, object.ClassName)

    if FindServiceSuccess and ServiceObject then
        return true
    end

    return false
end

-- Evaluating an instances' accessable "path" with just it's ref, and if
-- the root parent is nil/isn't under `game` or `workspace`, returns nil.
-- The use of this in encoding is optional, (false by default for
-- consistency) and will always fallback to `Instance.new(ClassName)`
local function EvaluateInstancePath(object, currentPath)
    currentPath = currentPath or ""

    local ObjectName = object.Name
    local ObjectClassName = object.ClassName
    local ObjectParent = object.Parent

    if ObjectParent == game and IsService(object) then
        -- ^^ Then we'll use GetService directly, since it's actually a service
        -- under the DataModel. FYI, GetService uses the ClassName of the
        -- service, not the "name"

        currentPath = ":GetService(" .. SerializeString(ObjectClassName) .. ")" .. currentPath
    elseif string.match(ObjectName, "^[A-Za-z_][A-Za-z0-9_]*$") then
        -- ^^ Like the `string` DataType, this means means we can
        -- index the name directly in Lua without an explicit string
        currentPath = "." .. ObjectName .. currentPath
    else
        currentPath = "[" .. SerializeString(ObjectName) .. "]" .. currentPath
    end

    -- These cases are SPECIFICALLY for getting if the path has reached the
    -- "end" for the evaluation process, including if the root parent is nil
    -- or isn't under the `game` DataModel
    if not ObjectParent then
        return -- Fallback, parent is nil etc
    elseif ObjectParent == game then
        currentPath = "game" .. currentPath
        return currentPath
    elseif ObjectParent == workspace then
        currentPath = "workspace" .. currentPath
        return currentPath
    end

    return EvaluateInstancePath(ObjectParent, currentPath)
end

--[[
<string> LuaEncode(<table> inputTable, <table?> options):

    ---------- SETTINGS: ----------

    PrettyPrinting <boolean?:false> | Whether or not the output should use pretty printing.

    IndentCount <number?:0> | The amount of "spaces" that should be indented per entry.

    OutputWarnings <boolean?:true> | If "warnings" should be placed to the output (as
    comments); It's recommended to keep this enabled, however this can be disabled at ease.

    StackLimit <number?:500> | The limit to the stack level before recursive encoding cuts
    off, and stops execution. This is used to prevent stack overflow errors and such. You
    could use `math.huge` here if you really wanted.

    FunctionsReturnRaw <boolean?:false> | If functions in said table return back a "raw"
    value to place in the output as the key/value.

    UseInstancePaths <boolean?:false> | If `Instance` reference objects should return their
    Lua-accessable path for encoding. If the instance is parented under `nil` or isn't under
    `game`/`workspace`, it'll always fall back to `Instance.new(ClassName)` as before.

]]
local function LuaEncode(inputTable, options)
    -- Check all arg and option types
    CheckType(inputTable, "inputTable", "table") -- Required*, nil not allowed
    options = CheckType(options, "options", "table", "nil") or {} -- `options` is an optional arg

    -- Options
    if options then
        CheckType(options.PrettyPrinting, "options.PrettyPrinting", "boolean", "nil")
        CheckType(options.IndentCount, "options.IndentCount", "number", "nil")
        CheckType(options.OutputWarnings, "options.OutputWarnings", "boolean", "nil")
        CheckType(options.StackLimit, "options.StackLimit", "number", "nil")
        CheckType(options.FunctionsReturnRaw, "options.FunctionsReturnRaw", "boolean", "nil")
        CheckType(options.UseInstancePaths, "options.UseInstancePaths", "boolean", "nil")
        
        -- Internal options:
        CheckType(options._StackLevel, "options._StackLevel", "number", "nil")
        CheckType(options._VisitedTables, "options._StackLevel", "table", "nil")
    end

    -- Because no if-else-then exp. in Lua 5.1+ (only Luau), for optional boolean values we need to check
    -- if it's nil first, THEN fall back to whatever it's actually set to if it's not nil
    local PrettyPrinting = (options.PrettyPrinting == nil and false) or options.PrettyPrinting
    local IndentCount = options.IndentCount or 0
    local OutputWarnings = (options.OutputWarnings == nil and true) or options.OutputWarnings
    local StackLimit = options.StackLimit or 500
    local FunctionsReturnRaw = (options.FunctionsReturnRaw == nil and false) or options.FunctionsReturnRaw
    local UseInstancePaths = (options.UseInstancePaths == nil and false) or options.UseInstancePaths
    
    -- Internal options:

    -- Internal stack level for depth checks and indenting
    local StackLevel = options._StackLevel or 1
    -- Set root as visited; cyclic detection
    local VisitedTables = options._VisitedTables or {[inputTable] = true} -- [`visitedTable <table>`] = `isVisited <boolean>`

    -- Stack overflow/output abuse or whatever, default StackLimit is 500
    -- FYI, this is just a very temporary solution for table cyclic refs
    if StackLevel >= StackLimit then
        return string.format("{--[[LuaEncode: Stack level limit of `%d` reached]]}", StackLimit)
    end

    -- Easy-to-reference values for specific args
    local NewEntryString = (PrettyPrinting and "\n") or ""
    local ValueSeperator = (PrettyPrinting and ", ") or ","

    -- For pretty printing (which is optional, and false by default) we need to keep track
    -- of the current stack, then repeat InitialIndentString by that count
    local InitialIndentString = string.rep(" ", IndentCount) -- If 0 this will just be ""
    local IndentString = (PrettyPrinting and InitialIndentString:rep(StackLevel)) or InitialIndentString

    local EndingString = (#IndentString > 0 and IndentString:sub(1, -IndentCount - 1)) or ""

    -- For number key values, incrementing the current internal index
    local KeyIndex = 1

    -- Cases (C-Like) for encoding values, then end setup. Using cases so no elseif bs!
    -- Functions are all expected to return a (<string> EncodedKey, <boolean?> EncloseInBrackets)
    local TypeCases = {} do
        -- Basic func for getting the direct value of an encoded type without weird table.pack()[1] syntax
        local function TypeCase(typeName, value)
            -- Each of these funcs return a tuple, so it'd be annoying to do case-by-case
            local EncodedValue = TypeCases[typeName](value, false) -- False to label as NOT `isKey`
            return EncodedValue
        end

        -- For "tuple" args specifically, so there isn't a bunch of re-used code
        local function Args(...)
            local EncodedValues = {}

            for _, Arg in {...} do
                table.insert(EncodedValues, TypeCase(
                    Type(Arg),
                    Arg
                ))
            end

            return table.concat(EncodedValues, ValueSeperator)
        end

        TypeCases["number"] = function(value, isKey)
            -- If the number isn't the current real index of the table, we DO want to
            -- explicitly define it in the serialization no matter what for accuracy
            if isKey and value == KeyIndex then
                -- ^^ What's EXPECTED unless otherwise explicitly defined, if so, return no encoded num
                KeyIndex = KeyIndex + 1
                return nil, false
            end

            -- Lua's internal `tostring` handling will denote positive/negativie-infinite number TValues as "inf", which
            -- makes certain numbers not encode properly. We also just want to make the output precise
            if value == PositiveInf then
                return "math.huge", true
            elseif value == NegativeInf then
                return "-math.huge", true
            end

            -- Return fixed-formatted precision num
            return string.format("%.16g", value), true -- True return for 2nd arg means it SHOULD be enclosed with brackets, if it is a key
        end

        TypeCases["string"] = function(value, isKey)
            if isKey and string.match(value, "^[A-Za-z_][A-Za-z0-9_]*$") then
                -- ^^ Then it's a syntaxically-correct variable, doesn't need explicit string def
                return value, false -- `EncloseInBrackets` false because ^^^
            end

            return SerializeString(value), true
        end

        TypeCases["table"] = function(value, isKey)
            -- Check duplicate/cyclic references
            do
                local VisitedTable = VisitedTables[value]
                if VisitedTable then
                    return string.format(
                        "{--[[LuaEncode: Duplicate reference%s]]}",
                        (value == inputTable and " (of parent)") or ""
                    )
                end

                VisitedTables[value] = true
            end

            -- Shallow clone original options tbl
            local NewOptions = ShallowClone(options) do
                -- Overriding if key because it'd look worse pretty printed in a key
                NewOptions.PrettyPrinting = (isKey and false) or (not isKey and PrettyPrinting)

                -- If PrettyPrinting is already false in the real args, set the indent to whatever
                -- the REAL IndentCount is set to
                NewOptions.IndentCount = (isKey and ((not PrettyPrinting and IndentCount) or 1)) or IndentCount

                -- Internal options
                NewOptions._StackLevel = (isKey and 1) or StackLevel + 1 -- If isKey, stack lvl is set to the **LOWEST** because it's the key to a value
                NewOptions._VisitedTables = VisitedTables
            end

            return LuaEncode(value, NewOptions), true
        end

        TypeCases["boolean"] = function(value)
            return tostring(value), true
        end

        TypeCases["nil"] = function(value)
            return "nil", true
        end

        TypeCases["function"] = function(value)
            -- If `FunctionsReturnRaw` is set as true, we'll call the function here itself, expecting
            -- a raw value for FunctionsReturnRaw to add as the key/value, you may want to do this for custom userdata or
            -- function closures. Thank's for listening to my Ted Talk!
            if FunctionsReturnRaw then
                return value(), true
            end

            -- If all else, force key func to return nil; can't handle a func val..
            return "function() --[[LuaEncode: `options.FunctionsReturnRaw` false, can't encode functions]] return end", true
        end

        ---------- ROBLOX CUSTOM DATATYPES BELOW ----------

        -- Axes.new()
        TypeCases["Axes"] = function(value)
            local EncodedArgs = {}
            local EnumValues = {
                ["Enum.Axis.X"] = value.X, -- These return bools
                ["Enum.Axis.Y"] = value.Y,
                ["Enum.Axis.Z"] = value.Z,
            }

            for EnumValue, IsEnabled in next, EnumValues do
                if IsEnabled then
                    table.insert(EncodedArgs, EnumValue)
                end
            end

            return string.format(
                "Axes.new(%s)",
                table.concat(EncodedArgs, ValueSeperator)
            ), true
        end

        -- BrickColor.new()
        TypeCases["BrickColor"] = function(value)
            -- BrickColor.Name represents exactly what we want to encode
            return string.format("BrickColor.new(%s)", TypeCase("string", value.Name)), true
        end

        -- CFrame.new()
        TypeCases["CFrame"] = function(value)
            return string.format(
                "CFrame.new(%s)",
                Args(value:components())
            ), true
        end

        -- CatalogSearchParams.new()
        TypeCases["CatalogSearchParams"] = function(value)
            return string.format(
                "(function(v, p) for pn, pv in next, p do v[pn] = pv end return v end)(%s)",
                table.concat(
                    {
                        "CatalogSearchParams.new()",
                        TypeCase("table", {
                            SearchKeyword = value.SearchKeyword,
                            MinPrice = value.MinPrice,
                            MaxPrice = value.MaxPrice,
                            SortType = value.SortType, -- EnumItem
                            CategoryFilter = value.CategoryFilter, -- EnumItem
                            BundleTypes = value.BundleTypes, -- table
                            AssetTypes = value.AssetTypes -- table
                        })
                    },
                    ValueSeperator
                )
            )
        end

        -- Color3.new()
        TypeCases["Color3"] = function(value)
            -- Using floats for RGB values, most accurate for direct serialization
            return string.format(
                "Color3.new(%s)",
                Args(value.R, value.G, value.B)
            ), true
        end

        -- ColorSequence.new(<ColorSequenceKeypoints>)
        TypeCases["ColorSequence"] = function(value)
            return string.format(
                "ColorSequence.new(%s)",
                TypeCase("table", value.Keypoints)
            ), true
        end

        -- ColorSequenceKeypoint.new()
        TypeCases["ColorSequenceKeypoint"] = function(value)
            return string.format(
                "ColorSequenceKeypoint.new(%s)",
                Args(value.Time, value.Value)
            ), true
        end

        -- DateTime.now()/DateTime.fromUnixTimestamp() | We're using fromUnixTimestamp to serialize the object
        TypeCases["DateTime"] = function(value)
            -- Always an int, we don't need to do anything special
            return string.format("DateTime.fromUnixTimestamp(%d)", value.UnixTimestamp), true
        end

        -- DockWidgetPluginGuiInfo.new() | Properties seem to throw an error on index if the scope isn't a Studio
        -- plugin, so we're directly getting values! (so fun!!!!)
        TypeCases["DockWidgetPluginGuiInfo"] = function(value)
            local ValueString = tostring(value) -- e.g.: "InitialDockState:Right InitialEnabled:0 InitialEnabledShouldOverrideRestore:0 FloatingXSize:0 FloatingYSize:0 MinWidth:0 MinHeight:0"

            return string.format(
                "DockWidgetPluginGuiInfo.new(%s)",
                Args(
                    -- InitialDockState (Enum.InitialDockState)
                    Enum.InitialDockState[string.match(ValueString, "InitialDockState:(%w+)")], -- Enum.InitialDockState.Right
                    -- InitialEnabled and InitialEnabledShouldOverrideRestore (boolean as number; `0` or `1`)
                    string.match(ValueString, "InitialEnabled:(%w+)") == "1", -- false
                    string.match(ValueString, "InitialEnabledShouldOverrideRestore:(%w+)") == "1", -- false
                    -- FloatingXSize/FloatingYSize (numbers)
                    tonumber(string.match(ValueString, "FloatingXSize:(%w+)")), -- 0
                    tonumber(string.match(ValueString, "FloatingYSize:(%w+)")), -- 0
                    -- MinWidth/MinHeight (numbers)
                    tonumber(string.match(ValueString, "MinWidth:(%w+)")), -- 0
                    tonumber(string.match(ValueString, "MinHeight:(%w+)")) -- 0
                )
            ), true
        end

        -- Enum (e.g. `Enum.UserInputType`)
        TypeCases["Enum"] = function(value)
            return "Enum." .. tostring(value), true -- For now, this is the behavior of enums in tostring.. I have no other choice atm
        end

        -- EnumItem | e.g. `Enum.UserInputType.Gyro`
        TypeCases["EnumItem"] = function(value)
            return tostring(value), true -- Returns the full enum index for now (e.g. "Enum.UserInputType.Gyro")
        end

        -- Enums | i.e. the `Enum` global return
        TypeCases["Enums"] = function(value)
            return "Enum", true
        end

        -- Faces.new() | Similar to Axes.new()
        TypeCases["Faces"] = function(value)
            local EncodedArgs = {}
            local EnumValues = {
                ["Enum.NormalId.Top"] = value.Top, -- These return bools
                ["Enum.NormalId.Bottom"] = value.Bottom,
                ["Enum.NormalId.Left"] = value.Left,
                ["Enum.NormalId.Right"] = value.Right,
                ["Enum.NormalId.Back"] = value.Back,
                ["Enum.NormalId.Front"] = value.Front,
            }

            for EnumValue, IsEnabled in next, EnumValues do
                if IsEnabled then
                    table.insert(EncodedArgs, EnumValue)
                end
            end

            return string.format(
                "Faces.new(%s)",
                table.concat(EncodedArgs, ValueSeperator)
            ), true
        end

        -- FloatCurveKey.new()
        TypeCases["FloatCurveKey"] = function(value)
            return string.format(
                "FloatCurveKey.new(%s)",
                Args(value.Time, value.Value, value.Interpolation)
            ), true
        end

        -- Font.new()
        TypeCases["Font"] = function(value)
            return string.format(
                "Font.new(%s)",
                Args(value.Family, value.Weight, value.Style)
            ), true
        end

        -- Instance.new() | Instance refs can be evaluated to their paths (optional), but if
        -- parented to nil or some DataModel not under `game`, it'll just return `Instance.new(ClassName)`
        TypeCases["Instance"] = function(value)
            if UseInstancePaths then
                local InstancePath = EvaluateInstancePath(value)
                if InstancePath then
                    return InstancePath, true
                end

                -- ^^ Now, if the path isn't accessable, falls back to the return below
            end

            return string.format("Instance.new(%s)", TypeCase("string", value.ClassName)), true
        end

        -- NumberRange.new()
        TypeCases["NumberRange"] = function(value)
            return string.format(
                "NumberRange.new(%s)",
                Args(value.Min, value.Max)
            ), true
        end

        -- NumberSequence.new(<NumberSequenceKeypoints>)
        TypeCases["NumberSequence"] = function(value)
            return string.format(
                "NumberSequence.new(%s)",
                TypeCase("table", value.Keypoints)
            ), true
        end

        -- NumberSequenceKeypoint.new()
        TypeCases["NumberSequenceKeypoint"] = function(value)
            return string.format(
                "NumberSequenceKeypoint.new(%s)",
                Args(value.Time, value.Value, value.Envelope)
            ), true
        end

        -- OverlapParams.new()
        TypeCases["OverlapParams"] = function(value)
            return string.format(
                "(function(v, p) for pn, pv in next, p do v[pn] = pv end return v end)(%s)",
                table.concat(
                    {
                        "OverlapParams.new()",
                        TypeCase("table", {
                            FilterDescendantsInstances = value.FilterDescendantsInstances,
                            FilterType = value.FilterType,
                            MaxParts = value.MaxParts,
                            CollisionGroup = value.CollisionGroup,
                            RespectCanCollide = value.RespectCanCollide
                        })
                    },
                    ValueSeperator
                )
            )
        end

        -- PathWaypoint.new()
        TypeCases["PathWaypoint"] = function(value)
            return string.format(
                "PathWaypoint.new(%s)",
                Args(value.Position, value.Action, value.Label)
            ), true
        end

        -- PhysicalProperties.new()
        TypeCases["PhysicalProperties"] = function(value)
            return string.format(
                "PhysicalProperties.new(%s)",
                Args(
                    value.Density,
                    value.Friction,
                    value.Elasticity,
                    value.FrictionWeight,
                    value.ElasticityWeight
                )
            ), true
        end

        -- Random.new()
        TypeCases["Random"] = function()
            return "Random.new()", true
        end

        -- Ray.new()
        TypeCases["Ray"] = function(value)
            return string.format(
                "Ray.new(%s)",
                Args(value.Origin, value.Direction)
            ), true
        end

        -- RaycastParams.new()
        TypeCases["RaycastParams"] = function(value)
            return string.format(
                "(function(v, p) for pn, pv in next, p do v[pn] = pv end return v end)(%s)",
                table.concat(
                    {
                        "RaycastParams.new()",
                        TypeCase("table", {
                            FilterDescendantsInstances = value.FilterDescendantsInstances,
                            FilterType = value.FilterType,
                            IgnoreWater = value.IgnoreWater,
                            CollisionGroup = value.CollisionGroup,
                            RespectCanCollide = value.RespectCanCollide
                        })
                    },
                    ValueSeperator
                )
            )
        end

        -- Rect.new()
        TypeCases["Rect"] = function(value)
            return string.format(
                "Rect.new(%s)",
                Args(value.Min, value.Max)
            ), true
        end

        -- Region3.new() | Roblox doesn't provide read properties for min/max on `Region3`, but they
        -- do on Region3int16.. Anyway, we CAN calculate the min/max of a Region3 from just .CFrame
        -- and .Size.. Thanks to wally for linking me the thread for this method lol
        TypeCases["Region3"] = function(value)
            local ValueCFrame = value.CFrame
            local ValueSize = value.Size

            -- These both are returned CFrames, we need to use Minimum.Position/Maximum.Position for the
            -- min/max args to Region3.new()
            local Minimum = ValueCFrame * CFrame.new(-ValueSize / 2)
            local Maximum = ValueCFrame * CFrame.new(ValueSize / 2)

            return string.format(
                "Region3.new(%s)",
                Args(Minimum.Position, Maximum.Position)
            ), true
        end

        -- Region3int16.new()
        TypeCases["Region3int16"] = function(value)
            return string.format(
                "Region3int16.new(%s)",
                Args(value.Min, value.Max)
            ), true
        end

        -- TweenInfo.new()
        TypeCases["TweenInfo"] = function(value)
            return string.format(
                "TweenInfo.new(%s)",
                Args(
                    value.Time,
                    value.EasingStyle,
                    value.EasingDirection,
                    value.RepeatCount,
                    value.Reverses,
                    value.DelayTime
                )
            ), true
        end

        -- RotationCurveKey.new() | UNDOCUMENTED
        TypeCases["RotationCurveKey"] = function(value)
            return string.format(
                "RotationCurveKey.new(%s)",
                Args(value.Time, value.Value, value.Interpolation)
            ), true
        end

        -- UDim.new()
        TypeCases["UDim"] = function(value)
            return string.format(
                "UDim.new(%s)",
                Args(value.Scale, value.Offset)
            ), true
        end

        -- UDim2.new()
        TypeCases["UDim2"] = function(value)
            return string.format(
                "UDim2.new(%s)",
                Args(
                    -- Not directly using X and Y UDims for better output (i.e. would
                    -- be UDim2.new(UDim.new(1, 0), UDim.new(1, 0)) if I did)
                    value.X.Scale,
                    value.X.Offset,
                    value.Y.Scale,
                    value.Y.Offset
                )
            ), true
        end

        -- Vector2.new()
        TypeCases["Vector2"] = function(value)
            return string.format(
                "Vector2.new(%s)",
                Args(value.X, value.Y)
            ), true
        end

        -- Vector2int16.new()
        TypeCases["Vector2int16"] = function(value)
            return string.format(
                "Vector2int16.new(%s)",
                Args(value.X, value.Y)
            ), true
        end

        -- Vector3.new()
        TypeCases["Vector3"] = function(value)
            return string.format(
                "Vector3.new(%s)",
                Args(value.X, value.Y, value.Z)
            ), true
        end

        -- Vector3int16.new()
        TypeCases["Vector3int16"] = function(value)
            return string.format(
                "Vector3int16.new(%s)",
                Args(value.X, value.Y, value.Z)
            ), true
        end

        -- `userdata`, just encode directly
        TypeCases["userdata"] = function(value)
            if getmetatable(value) then -- Has mt
                return "newproxy(true)", true
            else
                return "newproxy()", true -- newproxy() defaults to false (no mt)
            end
        end
    end

    -- Setup output tbl
    local EncodedEntries = {}

    for Key, Value in next, inputTable do
        local KeyType = Type(Key)
        local ValueType = Type(Value)

        if TypeCases[KeyType] and TypeCases[ValueType] then
            local EntryOutput = (PrettyPrinting and NewEntryString .. IndentString) or ""

            -- Go through and get key val
            local KeyEncodedSuccess, EncodedKeyOrError, EncloseInBrackets = pcall(TypeCases[KeyType], Key, true) -- The `true` represents if it's a key or not, here it is

            -- Ignoring 2nd arg (`EncloseInBrackets`) because this isn't the key
            local ValueEncodedSuccess, EncodedValueOrError = pcall(TypeCases[ValueType], Value, false) -- `false` because it's NOT the key, it's the value

            -- Im sorry for this logic chain here, I can't use `continue`/`continue()`.. :sob:
            -- Ignoring `if EncodedKeyOrError` because the key doesn't actually need to ALWAYS
            -- be explicitly encoded, like if it's a number of the current key index!
            if KeyEncodedSuccess and ValueEncodedSuccess and EncodedValueOrError then
                -- NOW we'll check for if the key was explicitly encoded, because we don't to stop
                -- the value from encoding, since we've already checked that and it *has* been
                local KeyValue = EncodedKeyOrError and ((EncloseInBrackets and string.format("[%s]", EncodedKeyOrError)) or EncodedKeyOrError) .. ((PrettyPrinting and " = ") or "=") or ""

                -- Encode key/value together, we've already checked if `EncodedValueOrError` was returned
                EntryOutput = EntryOutput .. KeyValue .. EncodedValueOrError
            elseif OutputWarnings then -- Then `Encoded(Key/Value)OrError` is the error msg
                -- ^^ Then either the key or value wasn't properly checked or encoded, and there
                -- was an error we need to log!
                local ErrorMessage = string.format(
                    "LuaEncode: Failed to encode %s of DataType `%s`: %s",
                    (not KeyEncodedSuccess and "key") or (not ValueEncodedSuccess and "value") or "key/value", -- "key/value" for bool type fallback
                    ValueType,
                    (not KeyEncodedSuccess and SerializeString(EncodedKeyOrError)) or (not ValueEncodedSuccess and SerializeString(EncodedValueOrError)) or "(Failed to get error message)"
                )

                EntryOutput = EntryOutput .. string.format(
                    "nil%s--[[%s]]",
                    (PrettyPrinting and " ") or "", -- Adding a space between `nil` or not
                    ErrorMessage:gsub("%[*%]*", "") -- Not using string global lib because it returns a tuple
                )
            end

            -- If there isn't another value after the current index, add ending formatting
            if not next(inputTable, Key) then
                EntryOutput = EntryOutput .. NewEntryString .. EndingString
            end

            table.insert(EncodedEntries, EntryOutput)
        end
    end

    -- Return wrapped table
    return "{" .. table.concat(EncodedEntries, ",") .. "}"
end

return LuaEncode
