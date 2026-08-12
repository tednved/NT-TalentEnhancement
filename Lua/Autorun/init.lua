-- 天赋增强-外科医生[SP] 辅助脚本
-- 与死神赛跑（tesp_laststand）：濒死锁血

-- 多人游戏必须由服务器执行；单人游戏保留本地执行。
if Game.IsMultiplayer and not SERVER then return end

local LASTSTAND_KEY = "tesp_laststand"
local AFTERMATH_KEY = "tesp_laststand_aftermath"
local LASTSTAND_ID = Identifier(LASTSTAND_KEY)
local AFTERMATH_ID = Identifier(AFTERMATH_KEY)
local SURGERY_ID = Identifier("surgery")

local LASTSTAND_BASE_DURATION = 60.0
local SURGERY_DURATION_MULTIPLIER = 0.1
local LASTSTAND_CHECK_INTERVAL = 60
local LASTSTAND_VITALITY_THRESHOLD = 0.01

local laststandCooldown = 0
local activeLastStands = {} -- character userdata -> true
local missingHealthFrameworkWarningShown = false

local function HasTalentSafe(character, talentKey)
    if character == nil then return false end
    -- 优先走 C# API（内部有防护）
    if character.HasTalent ~= nil then
        local ok, res = pcall(character.HasTalent, character, talentKey)
        if ok and res == true then return true end
    end
    -- 兜底：直接读 Info.UnlockedTalents（带 nil 检查）
    if character.Info ~= nil and character.Info.UnlockedTalents ~= nil then
        for value in character.Info.UnlockedTalents do
            if value.Value == talentKey then return true end
        end
    end
    return false
end

local function HasHealthFramework()
    return HF ~= nil and type(HF.SetAffliction) == "function"
end

local function GetAffliction(character, identifier)
    if character == nil or character.CharacterHealth == nil then return nil end
    return character.CharacterHealth.GetAffliction(identifier)
end

local function HasAffliction(character, identifier)
    local affliction = GetAffliction(character, identifier)
    if affliction == nil then return false end

    -- GetAffliction 在某些版本中可能返回一个 Strength 为 0 的实例；
    -- 这种实例不应该被视为仍然有效的 buff。
    local strength = affliction.Strength
    return strength == nil or strength > 0
end

local function SetAffliction(character, identifier, strength)
    if character == nil or character.CharacterHealth == nil then return end
    if not HasHealthFramework() then return end
    HF.SetAffliction(character, identifier, strength)
end

-- 锁血结束判定：曾经激活过、现在 buff 没了 -> 给后遗症。
local function FinishLastStand(character)
    if not activeLastStands[character] then return end

    activeLastStands[character] = nil
    if not HasAffliction(character, AFTERMATH_ID) then
        SetAffliction(character, AFTERMATH_KEY, 1)
    end
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
    if character ~= nil and character.GetSkillLevel ~= nil then
        surgery = character.GetSkillLevel(SURGERY_ID)
    end
    if type(surgery) ~= "number" then surgery = 0 end
    if surgery < 0 then surgery = 0 end

    return LASTSTAND_BASE_DURATION + surgery * SURGERY_DURATION_MULTIPLIER
end

local function TriggerLastStand(character)
    local duration = GetLastStandDuration(character)

    -- 先创建实例，再设置实例 Duration。Duration 属于 Affliction 实例，
    -- 不能只改 XML 或只改强度，否则会使用默认持续时间。
    SetAffliction(character, LASTSTAND_KEY, 1)
    local affliction = GetAffliction(character, LASTSTAND_ID)
    if affliction == nil then
        return false
    end

    affliction.Duration = duration
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
    if type(NT) ~= "table" or type(NT.ItemStartsWithMethods) ~= "table" then return end

    local originalWrench = NT.ItemStartsWithMethods.wrench
    if type(originalWrench) ~= "function" then return end

    local function BoneSetterWrench(item, usingCharacter, targetCharacter, limb)
        if usingCharacter ~= nil and targetCharacter ~= nil and limb ~= nil then
            local limbtype = HF.NormalizeLimbType(limb.type)
            if NT.LimbIsDislocated(targetCharacter, limbtype)
                and HasTalentSafe(usingCharacter, BONE_KEY) then
                -- 直接复位：无视镇痛与技能要求，绝不造成骨折
                NT.DislocateLimb(targetCharacter, limbtype, -1000)
                HF.GiveSkillScaled(usingCharacter, "medical", 4000)
                -- 保留剧痛：无镇痛时患者仍会哀嚎倒地（好玩）
                if not HF.HasAffliction(targetCharacter, "analgesia", 0.5) then
                    HF.AddAffliction(targetCharacter, "severepain", 5, usingCharacter)
                end
                return
            end
        end
        originalWrench(item, usingCharacter, targetCharacter, limb)
    end

    NT.ItemStartsWithMethods.wrench = BoneSetterWrench
    -- heavywrench/repairpack 在 NT 加载时按值拷贝了原函数，需一并替换
    if type(NT.ItemMethods) == "table" then
        NT.ItemMethods.heavywrench = BoneSetterWrench
        NT.ItemMethods.repairpack = BoneSetterWrench
    end
    wrenchWrapped = true
end

local function UpdateLastStand()
    WrapWrench() -- 一次性包装 NT wrench 方法（保证 NT 已加载）
    if not HasHealthFramework() then
        if not missingHealthFrameworkWarningShown then
            print("[天赋增强] 未找到 Neurotrauma HF.SetAffliction，锁血天赋不会运行。")
            missingHealthFrameworkWarningShown = true
        end
        return
    end

    if Character == nil or Character.CharacterList == nil then return end

    for _, character in pairs(Character.CharacterList) do
        if character ~= nil then
            -- 先处理死亡，再处理 buff。否则死亡角色仍带 buff 时会提前 continue，
            -- 导致 activeLastStands 残留且无法及时发放后遗症。
            if character.IsDead then
                FinishLastStand(character)
            elseif HasAffliction(character, LASTSTAND_ID) then
                -- 抗晕眩和稳定效果都由同一个 affliction 的存在时间控制。
                Stabilize(character)
            else
                FinishLastStand(character)

                if laststandCooldown <= 0
                    and HasTalentSafe(character, LASTSTAND_KEY)
                    and not HasAffliction(character, AFTERMATH_ID) then
                    local maxVitality = character.MaxVitality
                    if type(maxVitality) == "number"
                        and maxVitality > 0
                        and character.Vitality / maxVitality < LASTSTAND_VITALITY_THRESHOLD then
                        TriggerLastStand(character)
                    end
                end
            end
        end
    end

    if laststandCooldown <= 0 then
        laststandCooldown = LASTSTAND_CHECK_INTERVAL
    else
        laststandCooldown = laststandCooldown - 1
    end
end

Hook.Add("think", "tesp.laststand", UpdateLastStand)
