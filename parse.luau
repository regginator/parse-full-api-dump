--!nocheck
-- it's hackin time

local LuaEncode = require("libraries/LuaEncode")

-- Get full API dump (hacks real)
local StudioVersion = net.request({url = "https://setup.rbxcdn.com/versionQTStudio"}).body
local FullAPIDump = net.jsonDecode(net.request({url = `https://setup.rbxcdn.com/{StudioVersion}-Full-API-Dump.json`}).body)

if FullAPIDump.Version ~= 1 then
    print(`Full-API-Dump.json version invalid; expected 1, got {FullAPIDump.Version}`, 0)
    process.exit(1)
end

local function FileType(fileName)
    return string.match(fileName, `%.(.*)%w*$`)
end

-- For parsing all instance members as-is
local function GetInstanceMembers(apiDump)
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

-- CLI
local Args = process.args

if not Args[1] then
    print("No subcommand provided.\nUsage: `lune parse <subcommand> [OPTIONS]`")
    process.exit(1)
end

local Subcommand = string.lower(Args[1])

if Subcommand == "members" then
    local Path = Args[2] or "Members.lua"
    local PathFileType = FileType(Path)

    local InstanceMembers = GetInstanceMembers()
    local SerializedMembers = if PathFileType == "lua" or PathFileType == "luau" then
            "return " .. LuaEncode(InstanceMembers, {
                PrettyPrinting = true,
                IndentCount = 4
            })
        elseif PathFileType == "json" or PathFileType == "json5" then
            net.jsonEncode(InstanceMembers, true)
        else
            nil
    
    if not SerializedMembers then
        print(`File path for \`lune parse members\` must be *.lua, *.luau, *.json, or *.json5; got {tostring(PathFileType)}`)
        process.exit(1)
    end

    fs.writeFile(Path, SerializedMembers)
    print(`Wrote serialized members to {process.cwd}{Path}`)
end
