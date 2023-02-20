local LuaEncode = require("libraries/LuaEncode")

-- Get full API dump (hacks real)
local Version = net.request({url = "https://setup.rbxcdn.com/version-guid.txt"}).body
local FullAPIDump = net.jsonDecode(net.request({url = `https://setup.rbxcdn.com/{Version}-Full-API-Dump.json`}).body)

if FullAPIDump.Version ~= 1 then
    print(`Full-API-Dump.json version invalid; expected 1, got {FullAPIDump.Version}`, 0)
    process.exit(1)
end

local function FileType(fileName)
    return string.match(fileName, `%.(%w*)%s*$`)
end

local function SerializeOutput(inputTable, fileName)
    local PathFileType = FileType(fileName)

    local SerializedTable = if PathFileType == "lua" or PathFileType == "luau" then
            "return " .. LuaEncode(inputTable, {
                PrettyPrinting = true,
                IndentCount = 4
            })
        elseif PathFileType == "json" or PathFileType == "json5" then
            net.jsonEncode(inputTable, true)
        else
            nil
    
    if not SerializedTable then
        print(`File path must be *.lua, *.luau, *.json, or *.json5; got \"{tostring(PathFileType)}\"`)
        process.exit(1)
    end

    return SerializedTable
end

-- For parsing all instance members as-is
local function GetInstanceMembers()
    -- All complete instance members will be placed here
    local InstanceMembers = {}

    -- First, we'll get each class's individual members, and later after we track
    -- all inherited superclasses, we'll set them to `InstanceMembers`
    local IndividualInstanceMembers = {}

    -- Track all inherited super-classes on classes for later
    local InheritedClassBindings = {} -- [ClassName] = {...}

    -- Loop through all classes and set members in index order. This only get's a class's
    -- OWN members for now, inheritance will be handled next
    for _, ClassObject in FullAPIDump.Classes do
        local Members = {}

        -- Assign inherited classes (again, for later!)
        if ClassObject.Superclass ~= "<<<ROOT>>>" then
            local InheritedClasses = {ClassObject.Superclass}

            local SuperClassInheritedClasses = InheritedClassBindings[ClassObject.Superclass]
            if SuperClassInheritedClasses then
                for _, ClassName in SuperClassInheritedClasses do
                    table.insert(InheritedClasses, ClassName)
                end
            end

            InheritedClassBindings[ClassObject.Name] = InheritedClasses
        end

        -- Go through prop members of the current class now
        for _, MemberObject in ClassObject.Members do
            local MemberType = MemberObject.MemberType

            if not Members[MemberType] then
                Members[MemberType] = {}
            end

            table.insert(Members[MemberType], MemberObject.Name)
        end

        IndividualInstanceMembers[ClassObject.Name] = Members
    end

    -- Now, we'll bind all inherited properties for classes
    for ClassName, InheritedClasses in InheritedClassBindings do
        -- Shallow-clone the known individual members
        local ClassInstanceMembers = table.clone(IndividualInstanceMembers[ClassName])

        -- We now need to go through EVERY inherited class and get all members of those classes
        for _, InheritedClass in InheritedClasses do
            for MemberName, MemberValues in IndividualInstanceMembers[InheritedClass] do
                if not ClassInstanceMembers[MemberName] then
                    ClassInstanceMembers[MemberName] = {}
                end

                for _, MemberValue in MemberValues do
                    table.insert(ClassInstanceMembers[MemberName], MemberValue)
                end
            end
        end

        InstanceMembers[ClassName] = ClassInstanceMembers
    end

    return InstanceMembers
end

-- For getting all props
local function GetInstanceProperties(respectSerializationTags)
    local InstanceProperties = {}
    local IndividualInstanceProperties = {}
    local InheritedClassBindings = {}

    for _, ClassObject in FullAPIDump.Classes do
        local Properties = {}

        if ClassObject.Superclass ~= "<<<ROOT>>>" then
            local InheritedClasses = {ClassObject.Superclass}

            local SuperClassInheritedClasses = InheritedClassBindings[ClassObject.Superclass]
            if SuperClassInheritedClasses then
                for _, ClassName in SuperClassInheritedClasses do
                    table.insert(InheritedClasses, ClassName)
                end
            end

            InheritedClassBindings[ClassObject.Name] = InheritedClasses
        end

        for _, MemberObject in ClassObject.Members do
            if MemberObject.MemberType == "Property" and if respectSerializationTags then MemberObject.Serialization and MemberObject.Serialization.CanSave and MemberObject.Serialization.CanLoad else true then
                table.insert(Properties, MemberObject.Name)
            end
        end

        IndividualInstanceProperties[ClassObject.Name] = Properties
    end

    for ClassName, InheritedClasses in InheritedClassBindings do
        local ClassInstanceProperties = table.clone(IndividualInstanceProperties[ClassName])

        for _, InheritedClass in InheritedClasses do
            for _, PropertyName in IndividualInstanceProperties[InheritedClass] do
                table.insert(ClassInstanceProperties, PropertyName)
            end
        end

        InstanceProperties[ClassName] = ClassInstanceProperties
    end

    return InstanceProperties
end

-- CLI
if not fs.isDir("gen") then
    fs.writeDir("gen")
end

local Args = process.args

if not Args[1] then
    print("No subcommand provided.\nUsage: `lune parse <subcommand> [OPTIONS]`")
    process.exit(1)
end

local Subcommand = string.lower(Args[1])

if Subcommand == "members" then
    local Path = Args[2] or "gen/Members.lua"

    local InstanceMembers = GetInstanceMembers()
    local SerializedMembers = SerializeOutput(InstanceMembers, Path)

    fs.writeFile(Path, SerializedMembers)
    print(`Wrote serialized members to {process.cwd}{Path}`)
elseif Subcommand == "props" then
    local RespectSerializationTags = if Args[2] then string.lower(Args[2]) == "true" else false
    local Path = Args[3] or if RespectSerializationTags then "gen/SerializableProperties.lua" else "gen/Properties.lua"

    local InstanceProperties = GetInstanceProperties(RespectSerializationTags)
    local SerializedProperties = SerializeOutput(InstanceProperties, Path)

    fs.writeFile(Path, SerializedProperties)
    print(`Wrote serialized properties{if RespectSerializationTags then " (respecting serialization tags) " else " "}to {process.cwd}{Path}`)
end

process.exit(0)
