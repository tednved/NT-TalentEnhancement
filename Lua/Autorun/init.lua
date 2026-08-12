-- 天赋增强-外科医生[SP] 辅助脚本
-- 与死神赛跑（tesp_laststand）：濒死锁血

-- 多人游戏必须由服务器执行；单人游戏保留本地执行。
local isMultiplayer = false
pcall(function() isMultiplayer = Game ~= nil and Game.IsMultiplayer == true end)
if isMultiplayer and not SERVER then return end

local LASTSTAND_KEY = "tesp_laststand"
local AFTERMATH_KEY = "tesp_laststand_aftermath"
local LASTSTAND_ID = Identifier(LASTSTAND_KEY)
local AFTERMATH_ID = Identifier(AFTERMATH_KEY)
local SURGERY_ID = Identifier("surgery")

local LASTSTAND_BASE_DURATION = 60.0
local SURGERY_DURATION_MULTIPLIER = 0.1
local LASTSTAND_CHECK_INTERVAL = 60
local LASTSTAND_VITALITY_THRESHOLD = 0.01

local laststandCooldowns = {} -- character userdata -> 剩余冷却帧数（per-character，互不阻塞）
local activeLastStands = {} -- character userdata -> true
local talentIdentifierCache = {}
local missingHealthFrameworkWarningShown = false
local warnedRuntimeErrors = {}

-- Protect calls across the Lua/C# and dependency boundary. Runtime objects can disappear
-- during character removal or load-order changes; never let those errors escape a hook.
local function WarnRuntimeError(key, message)
    if warnedRuntimeErrors[key] then return end
    warnedRuntimeErrors[key] = true
    print("[TalentEnhancement] Suppressed runtime error (" .. key .. "): " .. tostring(message))
end

local function SafeGet(object, field, key)
    if object == nil then return nil end
    local ok, value = pcall(function() return object[field] end)
    if not ok then
        if key ~= nil then WarnRuntimeError(key, value) end
        return nil
    end
    return value
end

local function SafeSet(object, field, value, key)
    if object == nil then return false end
    local ok, err = pcall(function() object[field] = value end)
    if not ok then
        if key ~= nil then WarnRuntimeError(key, err) end
        return false
    end
    return true
end

-- Return the original function values; errors are swallowed instead of escaping to the game.
local function InvokeSafely(key, fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then
        WarnRuntimeError(key, a)
        return nil
    end
    return a, b, c, d
end

local function GetFunction(object, field)
    local value = SafeGet(object, field)
    if type(value) == "function" then return value end
    return nil
end

-- Invoke an instance member using normal LuaCs userdata syntax. Do not extract a
-- userdata method and pass the object manually: MoonSharp normally binds the instance
-- when the member is accessed through object[field](...).
local function InvokeMemberSafely(key, object, field, ...)
    if object == nil then return nil end
    local ok, a, b, c, d = pcall(function()
        return object[field](...)
    end)
    if not ok then
        WarnRuntimeError(key, a)
        return nil
    end
    return a, b, c, d
end

local function HasTalentSafe(character, talentKey)
    if character == nil then return false end

    -- Prefer the C# API. HasTalent takes an Identifier, not a raw string.
    local talentIdentifier = talentIdentifierCache[talentKey]
    if talentIdentifier == nil then
        talentIdentifier = Identifier(talentKey)
        talentIdentifierCache[talentKey] = talentIdentifier
    end
    if InvokeMemberSafely("talent.HasTalent", character, "HasTalent", talentIdentifier) == true then
        return true
    end

    local info = SafeGet(character, "Info", "talent.Info")
    local unlockedTalents = SafeGet(info, "UnlockedTalents", "talent.UnlockedTalents")
    if unlockedTalents ~= nil then
        local ok, found = pcall(function()
            for value in unlockedTalents do
                local valueString = SafeGet(value, "Value")
                if valueString == talentKey or value == talentIdentifier or value == talentKey then return true end
            end
            return false
        end)
        if not ok then
            WarnRuntimeError("talent.UnlockedTalents.iteration", found)
            return false
        end
        return found == true
    end
    return false
end

local function HasHealthFramework()
    return GetFunction(HF, "SetAffliction") ~= nil
end

local function GetAffliction(character, identifier)
    local health = SafeGet(character, "CharacterHealth", "affliction.CharacterHealth")
    if health == nil then return nil end
    -- CharacterHealth.GetAffliction accepts allowLimbAfflictions. These checks target
    -- character-wide afflictions, so explicitly exclude limb-only instances.
    return InvokeMemberSafely("affliction.GetAffliction", health, "GetAffliction", identifier, false)
end

local function HasAffliction(character, identifier)
    local affliction = GetAffliction(character, identifier)
    if affliction == nil then return false end

    -- Some versions can return a zero-strength instance; that is not an active buff.
    local ok, strength = pcall(function() return affliction.Strength end)
    if not ok then
        WarnRuntimeError("affliction.Strength", strength)
        return false
    end
    return strength == nil or (type(strength) == "number" and strength > 0)
end

local function SetAffliction(character, identifier, strength)
    if SafeGet(character, "CharacterHealth", "affliction.CharacterHealth") == nil then return false end
    local setAffliction = GetFunction(HF, "SetAffliction")
    if setAffliction == nil then return false end
    local ok, result = pcall(setAffliction, character, identifier, strength)
    if not ok then
        WarnRuntimeError("HF.SetAffliction", result)
        return false
    end
    return result ~= false
end

local function FinishLastStand(character)
    if not activeLastStands[character] then return end

    if not HasAffliction(character, AFTERMATH_ID)
        and not SetAffliction(character, AFTERMATH_KEY, 1) then
        return
    end
    activeLastStands[character] = nil
end

-- 稳定：血压 100、失血 0、心率类 affliction 归零。
local function Stabilize(character)
    SetAffliction(character, "bloodpressure", 100)
    SetAffliction(character, "bloodloss", 0)
    SetAffliction(character, "cardiacarrest", 0)
    SetAffliction(character, "tachycardia", 0)
    SetAffliction(character, "fibrillation", 0)
    SetAffliction(character, "heartattack", 0)
end

local function GetLastStandDuration(character)
    local surgery = 0
    if GetFunction(character, "GetSkillLevel") ~= nil then
        surgery = InvokeMemberSafely("character.GetSkillLevel.surgery", character,
            "GetSkillLevel", SURGERY_ID) or 0
    end
    if type(surgery) ~= "number" then surgery = 0 end
    if surgery < 0 then surgery = 0 end

    return LASTSTAND_BASE_DURATION + surgery * SURGERY_DURATION_MULTIPLIER
end

local function TriggerLastStand(character)
    local duration = GetLastStandDuration(character)

    -- 先创建实例，再设置实例 Duration。Duration 属于 Affliction 实例，
    -- 不能只改 XML 或只改强度，否则会使用默认持续时间。
    if not SetAffliction(character, LASTSTAND_KEY, 1) then
        return false
    end
    local affliction = GetAffliction(character, LASTSTAND_ID)
    if affliction == nil or not SafeSet(affliction, "Duration", duration, "laststand.Duration") then
        SetAffliction(character, LASTSTAND_KEY, 0)
        return false
    end

    activeLastStands[character] = true
    return true
end

local BONE_KEY = "tesp_bonefixer"
local wrenchWrapped = false

-- 骨科老中医（tesp_bonefixer）：治疗脱臼不依赖镇痛药、不造成骨折
-- 原版 NT 扳手机制（NT.ItemStartsWithMethods.wrench）：治疗脱臼需 60 医疗技能
--   （有 analgesia/肾上腺素时降为 30）；技能不足会 NT.BreakLimb 造成骨折；
--   无镇痛时给患者加 severepain（剧痛 → 哀嚎 + 眩晕倒地）。
-- 本天赋：无视镇痛与技能要求直接复位，绝不造成骨折，
--   但保留 severepain —— 患者依然会痛得哀嚎倒地。
local function WrapWrench()
    if wrenchWrapped then return end

    local itemStartsWithMethods = SafeGet(NT, "ItemStartsWithMethods", "wrench.ItemStartsWithMethods")
    local originalWrench = GetFunction(itemStartsWithMethods, "wrench")
    if originalWrench == nil then return end

    local normalizeLimbType = GetFunction(HF, "NormalizeLimbType")
    local limbIsDislocated = GetFunction(NT, "LimbIsDislocated")
    local dislocateLimb = GetFunction(NT, "DislocateLimb")
    local giveSkillScaled = GetFunction(HF, "GiveSkillScaled")
    local hasAffliction = GetFunction(HF, "HasAffliction")
    local addAffliction = GetFunction(HF, "AddAffliction")
    -- Do not permanently install a half-working wrapper while dependencies are still loading.
    if normalizeLimbType == nil or limbIsDislocated == nil or dislocateLimb == nil
        or giveSkillScaled == nil or hasAffliction == nil or addAffliction == nil then
        return
    end

    local function BoneSetterWrench(item, usingCharacter, targetCharacter, limb)
        if usingCharacter ~= nil and targetCharacter ~= nil and limb ~= nil
            and normalizeLimbType ~= nil and limbIsDislocated ~= nil and dislocateLimb ~= nil
            and giveSkillScaled ~= nil and hasAffliction ~= nil and addAffliction ~= nil
            and HasHealthFramework() then
            local limbType = InvokeSafely("wrench.NormalizeLimbType", normalizeLimbType, SafeGet(limb, "type"))
            local dislocated = limbType ~= nil
                and InvokeSafely("wrench.LimbIsDislocated", limbIsDislocated, targetCharacter, limbType) == true
            if dislocated and HasTalentSafe(usingCharacter, BONE_KEY) then
                -- Directly reset the limb, bypassing skill and analgesia requirements.
                InvokeSafely("wrench.DislocateLimb", dislocateLimb, targetCharacter, limbType, -1000)
                InvokeSafely("wrench.GiveSkillScaled", giveSkillScaled, usingCharacter, "medical", 4000)
                local hasAnalgesia = InvokeSafely("wrench.HasAffliction", hasAffliction, targetCharacter, "analgesia", 0.5)
                if hasAnalgesia ~= true then
                    InvokeSafely("wrench.AddAffliction", addAffliction, targetCharacter, "severepain", 5, usingCharacter)
                end
                return
            end
        end
        return InvokeSafely("wrench.original", originalWrench, item, usingCharacter, targetCharacter, limb)
    end

    if not SafeSet(itemStartsWithMethods, "wrench", BoneSetterWrench, "wrench.install") then return end

    -- These methods are copied by value by NT during load, so replace them too when present.
    local itemMethods = SafeGet(NT, "ItemMethods", "wrench.ItemMethods")
    if itemMethods ~= nil then
        SafeSet(itemMethods, "heavywrench", BoneSetterWrench, "wrench.install.heavywrench")
        SafeSet(itemMethods, "repairpack", BoneSetterWrench, "wrench.install.repairpack")
    end
    wrenchWrapped = true
end

local function UpdateLastStand()
    TryRegisterNTC() -- Retry until NTC has finished loading.
    WrapWrench() -- Retry until NT has finished loading.
    if not HasHealthFramework() then
        if not missingHealthFrameworkWarningShown then
            print("[TalentEnhancement] Neurotrauma HF.SetAffliction is unavailable; laststand is disabled.")
            missingHealthFrameworkWarningShown = true
        end
        return
    end

    local characterList = SafeGet(Character, "CharacterList", "character.CharacterList")
    if characterList == nil then return end

    for _, character in pairs(characterList) do
        if character ~= nil then
            local isDead = SafeGet(character, "IsDead", "laststand.IsDead") == true
            if isDead then
                FinishLastStand(character)
                laststandCooldowns[character] = nil
            elseif HasAffliction(character, LASTSTAND_ID) then
                -- Recover state after a script reload or a late-created affliction.
                activeLastStands[character] = true
                Stabilize(character)
            else
                FinishLastStand(character)

                local maxVitality = SafeGet(character, "MaxVitality", "laststand.MaxVitality")
                local vitality = SafeGet(character, "Vitality", "laststand.Vitality")
                if (laststandCooldowns[character] or 0) <= 0
                    and HasTalentSafe(character, LASTSTAND_KEY)
                    and not HasAffliction(character, AFTERMATH_ID)
                    and type(maxVitality) == "number"
                    and maxVitality > 0
                    and type(vitality) == "number"
                    and vitality / maxVitality < LASTSTAND_VITALITY_THRESHOLD then
                    TriggerLastStand(character)
                    laststandCooldowns[character] = LASTSTAND_CHECK_INTERVAL
                end
            end
            -- 每个角色独立的冷却递减（死亡角色条目已清理）
            local cd = laststandCooldowns[character]
            if cd ~= nil and cd > 0 then
                laststandCooldowns[character] = cd - 1
            end
        end
    end
end

Hook.Add("think", "tesp.laststand", function()
    InvokeSafely("laststand.think", UpdateLastStand)
end)

-- ============================================================
-- 身强体壮（buff）：骨折概率 -50%（NT anyfracturechance 乘数）
-- NTC.AddHumanUpdateHook 在 NT 每次更新清空乘数后运行（约每 2 秒一次），
-- 此时 SetMultiplier(0.5) 会从 1 稳定乘到 0.5，避免每帧累积。
-- ============================================================
local ntcHookRegistered = false
local function TryRegisterNTC()
    if ntcHookRegistered then return end
    local addHumanUpdateHook = GetFunction(NTC, "AddHumanUpdateHook")
    local setMultiplier = GetFunction(NTC, "SetMultiplier")
    if addHumanUpdateHook == nil or setMultiplier == nil then return end

    local ok, err = pcall(addHumanUpdateHook, function(character)
        InvokeSafely("NTC.humanUpdate", function()
            if character ~= nil and HasTalentSafe(character, "buff") then
                InvokeSafely("NTC.SetMultiplier", setMultiplier, character, "anyfracturechance", 0.5)
            end
        end)
    end)
    if ok then
        ntcHookRegistered = true
    else
        WarnRuntimeError("NTC.AddHumanUpdateHook", err)
    end
end

-- ============================================================
-- 老水手（crustyseaman）：受击后 10 秒内每秒修复 2 点普通出血（冷却 60 秒）
-- 只处理 limbspecific 的 bleeding（不含动脉破裂、内出血、手术未止血等特殊出血）
-- ============================================================
local CRUSTY_KEY = "crustyseaman"
local CRUSTY_ACTIVE_TIME = 10.0
local CRUSTY_COOLDOWN_TIME = 60.0
local CRUSTY_HEAL_PER_SECOND = 2.0

local crustyActive = {} -- character -> 剩余秒数
local crustyCooldown = {} -- character -> 剩余冷却秒数

Hook.Add("character.damageLimb", "tesp.crustyseaman", function(character)
    InvokeSafely("crusty.damageLimb", function()
        if character == nil or SafeGet(character, "IsDead", "crusty.IsDead") == true then return end
        if not HasTalentSafe(character, CRUSTY_KEY) then return end
        if (crustyCooldown[character] or 0) > 0 then return end
        crustyActive[character] = CRUSTY_ACTIVE_TIME
        crustyCooldown[character] = CRUSTY_COOLDOWN_TIME
    end)
end)

local function UpdateCrustySeaman(dt)
    local addAfflictionLimb = GetFunction(HF, "AddAfflictionLimb")
    if addAfflictionLimb == nil then return end

    if type(dt) ~= "number" or dt < 0 or dt ~= dt or dt > 10 then
        dt = 1 / 60
    end
    local characterList = SafeGet(Character, "CharacterList", "crusty.CharacterList")
    if characterList == nil then return end

    for _, character in pairs(characterList) do
        local isDead = character ~= nil and SafeGet(character, "IsDead", "crusty.IsDead") == true
        if character ~= nil and not isDead then
            if (crustyActive[character] or 0) > 0 then
                local animController = SafeGet(character, "AnimController", "crusty.AnimController")
                local limbs = SafeGet(animController, "Limbs", "crusty.Limbs")
                if limbs ~= nil and SafeGet(character, "CharacterHealth", "crusty.CharacterHealth") ~= nil then
                    for limb in limbs do
                        if limb ~= nil then
                            local limbType = SafeGet(limb, "type")
                            if limbType ~= nil then
                                InvokeSafely("HF.AddAfflictionLimb", addAfflictionLimb,
                                    character, "bleeding", limbType, -CRUSTY_HEAL_PER_SECOND * dt)
                            end
                        end
                    end
                end
                crustyActive[character] = crustyActive[character] - dt
                if crustyActive[character] <= 0 then crustyActive[character] = nil end
            end
            if (crustyCooldown[character] or 0) > 0 then
                crustyCooldown[character] = crustyCooldown[character] - dt
                if crustyCooldown[character] <= 0 then crustyCooldown[character] = nil end
            end
        elseif character ~= nil then
            crustyActive[character] = nil
            crustyCooldown[character] = nil
        end
    end
end

Hook.Add("think", "tesp.crustyseaman", function(dt)
    InvokeSafely("crusty.think", UpdateCrustySeaman,
        dt or (SafeGet(NT, "Deltatime") or 1 / 60))
end)

local IMPLACABLE_KEY = "implacable"
local IMPLACABLE_BUFF_KEY = "tesp_implacable"
local LASTWAVE_KEY = "tesp_lastwave"
local IMPLACABLE_ID = Identifier(IMPLACABLE_BUFF_KEY)
local LASTWAVE_ID = Identifier(LASTWAVE_KEY)
local VANILLA_IMPLACABLE_ID = Identifier("implacable")
local IMPLACABLE_BASE_DURATION = 20.0
local IMPLACABLE_WEAPONS_MULTIPLIER = 0.2

local activeImplacables = {} -- character -> true
local severedRestore = {} -- character -> { [limb] = true }
local traumaAmputationWrapped = false
local surgicalAmputationWrapped = false

-- 清除原版 implacable affliction（原版 15 秒触发仍可能存在，避免效果叠加）
local function CancelVanillaImplacable(character)
    if HasAffliction(character, VANILLA_IMPLACABLE_ID) then
        SetAffliction(character, "implacable", 0)
    end
end

local function GetImplacableDuration(character)
    local weapons = 0
    if GetFunction(character, "GetSkillLevel") ~= nil then
        weapons = InvokeMemberSafely("character.GetSkillLevel.weapons", character,
            "GetSkillLevel", Identifier("weapons")) or 0
    end
    if type(weapons) ~= "number" then weapons = 0 end
    if weapons < 0 then weapons = 0 end
    return IMPLACABLE_BASE_DURATION + weapons * IMPLACABLE_WEAPONS_MULTIPLIER
end

local function TriggerImplacable(character)
    local duration = GetImplacableDuration(character)

    CancelVanillaImplacable(character)
    if not SetAffliction(character, IMPLACABLE_BUFF_KEY, 1) then
        return false
    end
    local affliction = GetAffliction(character, IMPLACABLE_ID)
    if affliction == nil or not SafeSet(affliction, "Duration", duration, "implacable.Duration") then
        SetAffliction(character, IMPLACABLE_BUFF_KEY, 0)
        return false
    end
    activeImplacables[character] = true
    return true
end

-- Keep this mapping optional so a missing enum cannot abort the whole script at load time.
local AMPUTATION_AFFLICTIONS = {}
if LimbType ~= nil then
    local rightLeg = SafeGet(LimbType, "RightLeg")
    local leftLeg = SafeGet(LimbType, "LeftLeg")
    local rightArm = SafeGet(LimbType, "RightArm")
    local leftArm = SafeGet(LimbType, "LeftArm")
    local head = SafeGet(LimbType, "Head")
    if rightLeg ~= nil then AMPUTATION_AFFLICTIONS[rightLeg] = { "trl_amputation", "srl_amputation" } end
    if leftLeg ~= nil then AMPUTATION_AFFLICTIONS[leftLeg] = { "tll_amputation", "sll_amputation" } end
    if rightArm ~= nil then AMPUTATION_AFFLICTIONS[rightArm] = { "tra_amputation", "sra_amputation" } end
    if leftArm ~= nil then AMPUTATION_AFFLICTIONS[leftArm] = { "tla_amputation", "sla_amputation" } end
    if head ~= nil then AMPUTATION_AFFLICTIONS[head] = { "th_amputation", "sh_amputation" } end
end

-- During the buff, make already-severed limbs temporarily usable.
local function ApplySeveredImmunity(character)
    local animController = SafeGet(character, "AnimController", "implacable.AnimController")
    local limbs = SafeGet(animController, "Limbs", "implacable.Limbs")
    if limbs == nil then return end
    if severedRestore[character] == nil then severedRestore[character] = {} end
    for limb in limbs do
        if limb ~= nil and SafeGet(limb, "IsSevered", "implacable.IsSevered") == true then
            severedRestore[character][limb] = true
            SafeSet(limb, "IsSevered", false, "implacable.clearSevered")
        end
    end
end

local function RestoreSevered(character)
    local restore = severedRestore[character]
    if restore == nil then return end

    local hasAffliction = GetFunction(HF, "HasAffliction")
    for limb in pairs(restore) do
        if limb ~= nil then
            local limbType = SafeGet(limb, "type", "implacable.limbType")
            local affs = limbType ~= nil and AMPUTATION_AFFLICTIONS[limbType] or nil
            local stillAmputated = false
            if affs ~= nil then
                for _, aff in ipairs(affs) do
                    local present
                    if hasAffliction ~= nil then
                        present = InvokeSafely("HF.HasAffliction", hasAffliction, character, aff, 0.5)
                    else
                        present = HasAffliction(character, aff)
                    end
                    if present == true then
                        stillAmputated = true
                        break
                    end
                end
            end
            if stillAmputated then
                SafeSet(limb, "IsSevered", true, "implacable.restoreSevered")
            end
        end
    end
    severedRestore[character] = nil
end

local function FinishImplacable(character)
    if not activeImplacables[character] then return end
    RestoreSevered(character)
    if not HasAffliction(character, LASTWAVE_ID)
        and not SetAffliction(character, LASTWAVE_KEY, 1) then
        return
    end
    activeImplacables[character] = nil
end

local function UpdateImplacable()
    local characterList = SafeGet(Character, "CharacterList", "implacable.CharacterList")
    if characterList == nil then return end

    for _, character in pairs(characterList) do
        if character ~= nil then
            local isDead = SafeGet(character, "IsDead", "implacable.IsDead") == true
            if isDead then
                FinishImplacable(character)
            elseif HasAffliction(character, IMPLACABLE_ID) then
                -- Recover state after a script reload or a late-created affliction.
                activeImplacables[character] = true
                ApplySeveredImmunity(character)
                CancelVanillaImplacable(character)
            else
                FinishImplacable(character)
                local maxVitality = SafeGet(character, "MaxVitality", "implacable.MaxVitality")
                local vitality = SafeGet(character, "Vitality", "implacable.Vitality")
                if HasTalentSafe(character, IMPLACABLE_KEY)
                    and not HasAffliction(character, LASTWAVE_ID)
                    and not activeImplacables[character]
                    and type(maxVitality) == "number"
                    and maxVitality > 0
                    and type(vitality) == "number"
                    and vitality <= 0 then
                    TriggerImplacable(character)
                end
            end
        end
    end
end

-- Block new amputations while the buff is active. Retry independently for each NT API,
-- because load order can expose the two functions on different frames.
local function WrapAmputations()
    local function IsActive(character)
        return character ~= nil and activeImplacables[character] == true
    end

    if not traumaAmputationWrapped then
        local original = GetFunction(NT, "TraumamputateLimb")
        if original ~= nil then
            local wrapped = function(character, limbType, attacker)
                if IsActive(character) then return end
                return InvokeSafely("NT.TraumamputateLimb", original, character, limbType, attacker)
            end
            if SafeSet(NT, "TraumamputateLimb", wrapped, "amputation.wrap.trauma") then
                traumaAmputationWrapped = true
            end
        end
    end

    if not surgicalAmputationWrapped then
        local original = GetFunction(NT, "SurgicallyAmputateLimb")
        if original ~= nil then
            local wrapped = function(character, limbType, strength, traumampstrength)
                if IsActive(character) then return end
                return InvokeSafely("NT.SurgicallyAmputateLimb", original,
                    character, limbType, strength, traumampstrength)
            end
            if SafeSet(NT, "SurgicallyAmputateLimb", wrapped, "amputation.wrap.surgical") then
                surgicalAmputationWrapped = true
            end
        end
    end
end

local function UpdateImplacableWrapped()
    WrapAmputations()
    UpdateImplacable()
end

Hook.Add("think", "tesp.implacable", function()
    InvokeSafely("implacable.think", UpdateImplacableWrapped)
end)
