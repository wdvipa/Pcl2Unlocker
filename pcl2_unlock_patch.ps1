# PCL2 下载限制解除补丁（重跑可重复使用）
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File .\pcl2_unlock_patch.ps1
# 作用: 解除 PCL2 正式版 (413+) 的 MC 下载封锁（下载页 + 整合包安装分发）
# 原理: 见 https://github.com/Meloong-Git/PCL 源码中 RestrictMcDownload 编译期常量折叠
#       1) PageDownloadInstall/_Closure$__._Lambda$__3-0 (无条件 throw 桩) -> ret
#       2) ModModpack.ModpackInstall(3参) 的 throw 桩 -> 重建 Select Case 分发, 接回 InstallPack*
$ErrorActionPreference = 'Stop'
$work = "$env:TEMP\pcl_patch"

# ============ exe 发现与选择 (P 优先) ============
$knownNames = @('Plain Craft Launcher 2.exe', 'PCL2.exe', 'pcl2.exe')
$allExe = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.exe' -File -ErrorAction SilentlyContinue)
if ($allExe.Count -eq 0) { throw "未在 $PSScriptRoot 找到任何 .exe 文件" }

# 排序: 1) 精确已知名置顶 2) P/p 开头 3) 其余按名
$ranked = $allExe | Sort-Object `
    @{ Expression = { if ($knownNames -contains $_.Name) { 0 } else { 1 } } }, `
    @{ Expression = { if ($_.Name -match '^[Pp]') { 0 } else { 1 } } }, `
    Name

# 自动选择: 仅当恰好一个已知名命中
$knownHits = @($ranked | Where-Object { $knownNames -contains $_.Name })
if ($knownHits.Count -eq 1) {
    $exe = $knownHits[0].FullName
    Write-Host "自动选择: $($knownHits[0].Name)" -ForegroundColor Green
} else {
    Write-Host "检测到以下 exe (P 优先排序):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $ranked.Count; $i++) {
        $mark = if ($knownNames -contains $ranked[$i].Name) { ' [推荐]' } else { '' }
        Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $ranked[$i].Name, $mark)
    }
    do {
        $sel = Read-Host "请输入编号 (1-$($ranked.Count))"
        $ok = $false
        if ($sel -match '^\d+$') {
            $n = [int]$sel
            if ($n -ge 1 -and $n -le $ranked.Count) { $ok = $true }
        }
    } until ($ok)
    $exe = $ranked[$n - 1].FullName
    Write-Host "已选择: $($ranked[$n - 1].Name)" -ForegroundColor Green
}
if (-not (Test-Path $exe)) { throw "选中的文件不存在: $exe" }

try {

# 0) 工具链
New-Item -ItemType Directory -Force $work | Out-Null
if (-not (Test-Path "$work\cecil\lib\net40\Mono.Cecil.dll")) {
    Invoke-WebRequest -Uri 'https://www.nuget.org/api/v2/package/Mono.Cecil/0.11.5' -OutFile "$work\cecil.zip"
    Expand-Archive "$work\cecil.zip" "$work\cecil" -Force
}
Add-Type -Path "$work\cecil\lib\net40\Mono.Cecil.dll"

# 1) 备份
Copy-Item $exe "$work\original_backup.exe" -Force

# 2) 确定缺失的引用程序集, 生成带类型 stub 的空壳 (仅满足 Cecil 写回校验, 运行时用不到)
$rpp0 = New-Object Mono.Cecil.ReaderParameters; $rpp0.ReadingMode = [Mono.Cecil.ReadingMode]::Deferred
$tmp = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($exe, $rpp0)
$resolver = New-Object Mono.Cecil.DefaultAssemblyResolver
$resolver.AddSearchDirectory($work)
$resolver.AddSearchDirectory([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory())
$need = @{}
foreach ($tr in $tmp.MainModule.GetTypeReferences()) {
    $scope = $tr.Scope
    if ($scope -is [Mono.Cecil.AssemblyNameReference]) { $need[$scope.Name] = $scope }
}
$dummyNames = @()
foreach ($name in @($need.Keys)) {
    $anr = $need[$name]
    $found = $false
    try { $a = $resolver.Resolve($anr); if ($a) { $found = $true; $a.Dispose() } } catch { }
    if (-not $found) {
        $dummyNames += $name
        $dn = New-Object Mono.Cecil.AssemblyNameDefinition($name, $anr.Version)
        $d = [Mono.Cecil.AssemblyDefinition]::CreateAssembly($dn, "$name.dll", [Mono.Cecil.ModuleKind]::Dll)
        $ms = New-Object System.IO.MemoryStream
        $d.Write($ms); $d.Dispose()
        [System.IO.File]::WriteAllBytes("$work\$name.dll", $ms.ToArray())
    }
}
foreach ($name in $dummyNames) {
    # 收集该程序集 scope 下的类型引用
    $types = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($tr in $tmp.MainModule.GetTypeReferences()) {
        $scope = $tr.Scope
        if ($scope -is [Mono.Cecil.AssemblyNameReference] -and $scope.Name -eq $name) { [void]$types.Add($tr.FullName) }
    }
    $bytes = [System.IO.File]::ReadAllBytes("$work\$name.dll")
    $ms = New-Object System.IO.MemoryStream(, $bytes)
    $ad = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($ms)
    foreach ($full in $types) {
        $parts = $full -split '/'; $cur = $null
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $p = $parts[$i]
            if ($i -eq 0) {
                if ($p -match '^(.*)\.([^\./]+)$') { $ns = $Matches[1]; $tn = $Matches[2] } else { $ns = ''; $tn = $p }
                $ex = $ad.MainModule.Types | Where-Object { $_.FullName -eq $p }
                if (-not $ex) {
                    $td = New-Object Mono.Cecil.TypeDefinition($ns, $tn, ([Mono.Cecil.TypeAttributes]'Public, Class, AutoLayout, AnsiClass, BeforeFieldInit'))
                    $ad.MainModule.Types.Add($td)
                }
                $cur = $ad.MainModule.Types | Where-Object { $_.FullName -eq $p }
            } else {
                $ex = $cur.NestedTypes | Where-Object { $_.Name -eq $p }
                if (-not $ex) {
                    $td = New-Object Mono.Cecil.TypeDefinition('', $p, ([Mono.Cecil.TypeAttributes]'NestedPublic, Class, AutoLayout, AnsiClass, BeforeFieldInit'))
                    $cur.NestedTypes.Add($td)
                }
                $cur = $cur.NestedTypes | Where-Object { $_.Name -eq $p }
            }
        }
    }
    $ms2 = New-Object System.IO.MemoryStream
    $ad.Write($ms2); $ad.Dispose()
    [System.IO.File]::WriteAllBytes("$work\$name.dll", $ms2.ToArray())
    $ms.Dispose()
}
$tmp.Dispose()
"stub 程序集: $($dummyNames -join ', ')"

# 3) 打补丁
$rpp = New-Object Mono.Cecil.ReaderParameters; $rpp.AssemblyResolver = $resolver
$rp = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($exe, $rpp)
$mod = $rp.MainModule

# P1: 下载页 loader 桩 -> ret
$pg = $mod.Types | Where-Object { $_.FullName -eq 'PCL.PageDownloadInstall' }
$lm = $pg.NestedTypes[0].Methods | Where-Object { $_.Name -eq '_Lambda$__3-0' }
$lm.Body.Instructions.Clear()
($lm.Body.GetILProcessor()).Emit([Mono.Cecil.Cil.OpCodes]::Ret)
"P1: 下载页 throw 桩 -> ret"

# P2: ModpackInstall(3参) 的 throw 桩 -> Select Case 分发
$t = $mod.Types | Where-Object { $_.FullName -eq 'PCL.ModModpack' }
$m = $t.Methods | Where-Object { $_.Name -eq 'ModpackInstall' -and $_.Parameters.Count -eq 3 }
$ins = $m.Body.Instructions; $body = $m.Body; $ip = $body.GetILProcessor()
$join = $ins | Where-Object { $_.OpCode.Name -eq 'ldstr' -and $_.Operand -like '*暂时不再提供*' }
if (-not $join) {
    "P2: 已打过, 跳过"
} else {
$V4 = $body.Variables | Where-Object { $_.Index -eq 4 }
$idx = $ins.IndexOf($join); $dead1 = $ins[$idx + 1]; $dead2 = $ins[$idx + 2]
$join.OpCode = [Mono.Cecil.Cil.OpCodes]::Ldloc_S; $join.Operand = $V4
$last = $ins[$ins.Count - 1]
$epi0 = $ip.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_0); $epi1 = $ip.Create([Mono.Cecil.Cil.OpCodes]::Ret)
$ip.InsertAfter($last, $epi0) | Out-Null; $ip.InsertAfter($epi0, $epi1) | Out-Null
$cf = $t.Methods | Where-Object { $_.Name -eq 'InstallPackCurseForge' }; $mr = $t.Methods | Where-Object { $_.Name -eq 'InstallPackModrinth' }
$hm = $t.Methods | Where-Object { $_.Name -eq 'InstallPackHMCL' }; $mm = $t.Methods | Where-Object { $_.Name -eq 'InstallPackMMC' }
$mb = $t.Methods | Where-Object { $_.Name -eq 'InstallPackMCBBS' }; $lp = $t.Methods | Where-Object { $_.Name -eq 'InstallPackLauncherPack' }
$cp = $t.Methods | Where-Object { $_.Name -eq 'InstallPackCompress' }
function New-Case($callIns, $n) {
    $b = New-Object System.Collections.Generic.List[Mono.Cecil.Cil.Instruction]
    $b.Add($ip.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)); $b.Add($ip.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_1)); $b.Add($ip.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_2))
    if ($n -eq 5) { $b.Add($ip.Create([Mono.Cecil.Cil.OpCodes]::Ldnull)); $b.Add($ip.Create([Mono.Cecil.Cil.OpCodes]::Ldnull)) }
    elseif ($n -eq 4) { $b.Add($ip.Create([Mono.Cecil.Cil.OpCodes]::Ldnull)) }
    $b.Add($callIns); $b.Add($ip.Create([Mono.Cecil.Cil.OpCodes]::Stloc_0)); $b.Add($ip.Create([Mono.Cecil.Cil.OpCodes]::Leave, $epi0))
    return $b
}
$b0 = New-Case ([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $cf)) 5
$b1 = New-Case ([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $hm)) 3
$b2 = New-Case ([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $mm)) 3
$b3 = New-Case ([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $mb)) 4
$b4 = New-Case ([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $mr)) 5
$b9 = New-Case ([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $lp)) 3
$be = New-Case ([Mono.Cecil.Cil.Instruction]::Create([Mono.Cecil.Cil.OpCodes]::Call, $cp)) 2
$chain = New-Object System.Collections.Generic.List[Mono.Cecil.Cil.Instruction]
foreach ($pair in @(@(0, $b0), @(1, $b1), @(2, $b2), @(3, $b3), @(4, $b4), @(9, $b9))) {
    $chain.Add($ip.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4, $pair[0]))
    $chain.Add($ip.Create([Mono.Cecil.Cil.OpCodes]::Beq, $pair[1][0]))
}
$chain.Add($ip.Create([Mono.Cecil.Cil.OpCodes]::Br, $be[0]))
$cursor = $join
foreach ($x in ($chain + $b0 + $b1 + $b2 + $b3 + $b4 + $b9 + $be)) { $ip.InsertAfter($cursor, $x) | Out-Null; $cursor = $x }
$ins.Remove($dead1) | Out-Null; $ins.Remove($dead2) | Out-Null
"P2: 整合包分发重建, IL $($ins.Count) 条"
}

# ============ 第二轮 ============

# P3: PageDownloadInstall.LoaderInit -> 真正的 DlClientListLoader (版本列表)
$md = $mod.Types | Where-Object { $_.FullName -eq 'PCL.ModDownload' }
$dlField = $md.Fields | Where-Object { $_.Name -eq 'DlClientListLoader' }
$li = $pg.Methods | Where-Object { $_.Name -eq 'LoaderInit' }
$insL = $li.Body.Instructions; $ipL = $li.Body.GetILProcessor()
$startL = $insL | Where-Object { $_.OpCode.Name -eq 'ldstr' -and $_.Operand -eq '关闭下载' }
if (-not $startL) {
    "P3: 已打过, 跳过"
} else {
$newTaskL = $insL | Where-Object { $_.OpCode.Name -eq 'newobj' -and $_.Operand.Name -eq '.ctor' -and ($_.Operand.DeclaringType.Name -like 'LoaderTask*') -and $insL.IndexOf($_) -gt $insL.IndexOf($startL) } | Select-Object -First 1
$ldfldL = $ipL.Create([Mono.Cecil.Cil.OpCodes]::Ldsfld, $dlField)
$ipL.InsertBefore($startL, $ldfldL) | Out-Null
$fromL = $insL.IndexOf($ldfldL) + 1; $toL = $insL.IndexOf($newTaskL)
for ($k = $toL; $k -ge $fromL; $k--) { $insL.RemoveAt($k) }
"P3: LoaderInit -> DlClientListLoader"
}

# P4: PageDownloadModify.LoadInstanceFinished: CardMinecraft Collapsed -> Visible
$pm2 = $mod.Types | Where-Object { $_.FullName -eq 'PCL.PageDownloadModify' }
$lf2 = $pm2.Methods | Where-Object { $_.Name -eq 'LoadInstanceFinished' }
$ilP4 = $lf2.Body.Instructions; $fixed4 = $false
for ($i = 0; $i -lt $ilP4.Count - 2; $i++) {
    $op = $ilP4[$i].Operand
    if (($ilP4[$i].OpCode.Name -in @('call', 'callvirt')) -and $op -is [Mono.Cecil.MethodReference] -and $op.Name -eq 'get_CardMinecraft' `
        -and $ilP4[$i + 1].OpCode.Name -eq 'ldc.i4.2' -and $ilP4[$i + 2].OpCode.Name -eq 'callvirt' -and $ilP4[$i + 2].Operand.Name -eq 'set_Visibility') {
        $ilP4[$i + 1].OpCode = [Mono.Cecil.Cil.OpCodes]::Ldc_I4_0; $fixed4 = $true; break
    }
}
if (-not $fixed4) { "P4: 已打过或未找到, 跳过" } else { "P4: CardMinecraft -> Visible" }

# P5: PageDownloadResourceDetail.InitializeStackResourceVersions: ModPack 行恢复 Install_Click
$pd5 = $mod.Types | Where-Object { $_.FullName -eq 'PCL.PageDownloadResourceDetail' }
$mC5 = $pd5.Methods | Where-Object { $_.Name -eq 'InitializeStackResourceVersions' }
$ilC5 = $mC5.Body.Instructions; $ipC5 = $mC5.Body.GetILProcessor()
$fIdx = -1
for ($i = 0; $i -lt $ilC5.Count; $i++) {
    if ($ilC5[$i].OpCode.Name -eq 'ldftn' -and $ilC5[$i].Operand.Name -eq 'Save_Click') { $fIdx = $i; break }
    if ($ilC5[$i].OpCode.Name -eq 'ldftn' -and $ilC5[$i].Operand.Name -eq 'Install_Click') { $fIdx = -1; break }
}
if ($fIdx -lt 0) {
    "P5: 已打过, 跳过"
} else {
$itemInstr = $ilC5[$fIdx - 2]
$newobjRef5 = $ilC5[$fIdx + 1].Operand
$toListRef5 = $ilC5[$fIdx + 4].Operand
$addInstr5 = $ilC5[$fIdx + 5]
$trtField = $pd5.Fields | Where-Object { $_.Name -eq 'TargetResourceType' }
$instFtn = $ipC5.Create([Mono.Cecil.Cil.OpCodes]::Ldftn, ($pd5.Methods | Where-Object { $_.Name -eq 'Install_Click' }))
$new5 = @()
$new5 += $ipC5.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
$new5 += $ipC5.Create([Mono.Cecil.Cil.OpCodes]::Ldfld, $trtField)
$new5 += $ipC5.Create([Mono.Cecil.Cil.OpCodes]::Ldc_I4_2)
$new5 += $ipC5.Create([Mono.Cecil.Cil.OpCodes]::Bne_Un_S, $itemInstr)
$new5 += $ipC5.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_S, $itemInstr.Operand)
$new5 += $ipC5.Create([Mono.Cecil.Cil.OpCodes]::Ldarg_0)
$new5 += $instFtn
$new5 += $ipC5.Create([Mono.Cecil.Cil.OpCodes]::Newobj, $newobjRef5)
$new5 += $ipC5.Create([Mono.Cecil.Cil.OpCodes]::Ldnull)
$new5 += $ipC5.Create([Mono.Cecil.Cil.OpCodes]::Ldloc_1)
$new5 += $ipC5.Create([Mono.Cecil.Cil.OpCodes]::Callvirt, $toListRef5)
$new5 += $ipC5.Create([Mono.Cecil.Cil.OpCodes]::Br_S, $addInstr5)
for ($k = $new5.Count - 1; $k -ge 0; $k--) { $ipC5.InsertBefore($itemInstr, $new5[$k]) | Out-Null }
"P5: ModPack 详情页恢复 Install_Click"
}

# P6: ModpackInstall() 恢复"选择整合包文件"入口
$mm6 = $mod.Types | Where-Object { $_.FullName -eq 'PCL.ModModpack' }
$m06 = $mm6.Methods | Where-Object { $_.Name -eq 'ModpackInstall' -and $_.Parameters.Count -eq 0 }
$alreadyD = $m06.HasBody -and ($m06.Body.Instructions | Where-Object { $_.Operand -is [Mono.Cecil.MethodReference] -and $_.Operand.Name -eq 'SelectFile' })
if ($alreadyD) {
    "P6: 已打过, 跳过"
} else {
$closure6 = $mm6.NestedTypes | Where-Object { $_.Name -eq '_Closure$__0-0' }
$closureField6 = $closure6.Fields | Where-Object { $_.Name -eq '$VB$Local_File' }
$closureLambda6 = $closure6.Methods | Where-Object { $_.Name -eq '_Lambda$__0' }
$pim6 = $mod.Types | Where-Object { $_.FullName -eq 'PCL.PageInstanceMod' }
$bm6 = $pim6.Methods | Where-Object { $_.Name -eq 'BtnManageInstall_Click' }
$selRef = $null; $ftuRef = $null; $vtCtor = $null; $oneOfImpl = $null; $nulCtor = $null
foreach ($x in $bm6.Body.Instructions) {
    $op = $x.Operand
    if ($op -is [Mono.Cecil.MethodReference]) {
        if ($op.Name -eq 'SelectFile') { $selRef = $op }
        if ($x.OpCode.Name -eq 'newobj' -and $op.DeclaringType.Name -like 'ValueTuple*') { $vtCtor = $op }
        if ($x.OpCode.Name -eq 'call' -and $op.Name -eq 'op_Implicit' -and $op.DeclaringType.Name -like 'OneOf*') { $oneOfImpl = $op }
        if ($x.OpCode.Name -eq 'newobj' -and $op.DeclaringType.Name -like 'Nullable*1') { $nulCtor = $op }
    }
}
$mj6 = $mod.Types | Where-Object { $_.FullName -eq 'PCL.ModJava' }
foreach ($x in ($mj6.Methods | Where-Object { $_.Name -eq 'ManuallyImportJava' }).Body.Instructions) {
    $op = $x.Operand
    if ($op -is [Mono.Cecil.MethodReference] -and $op.Name -eq 'FirstOrDefault' -and $op.DeclaringType.Name -eq 'Enumerable') { $ftuRef = $op }
}
$runRef = $null; $actCtor = $null
foreach ($tt in $mod.Types) {
    foreach ($mmt in ($tt.Methods | Where-Object { $_.HasBody })) {
        foreach ($x in $mmt.Body.Instructions) {
            $op = $x.Operand
            if ($op -is [Mono.Cecil.MethodReference]) {
                if (-not $runRef -and $op.Name -eq 'RunInThread' -and $op.DeclaringType.Name -eq 'ModBase') { $runRef = $op }
                if (-not $actCtor -and $x.OpCode.Name -eq 'newobj' -and $op.Name -eq '.ctor' -and $op.DeclaringType.Name -eq 'Action`1' -and $op.DeclaringType.Namespace -eq 'System') { $actCtor = $op }
            }
        }
    }
}
$body6 = $m06.Body; $body6.Instructions.Clear(); $body6.Variables.Clear()
$v06 = New-Object Mono.Cecil.Cil.VariableDefinition($selRef.ReturnType)
$v16 = New-Object Mono.Cecil.Cil.VariableDefinition($ftuRef.ReturnType)
$v26 = New-Object Mono.Cecil.Cil.VariableDefinition($closure6)
$body6.Variables.Add($v06); $body6.Variables.Add($v16); $body6.Variables.Add($v26)
$body6.InitLocals = $true; $body6.MaxStackSize = 8
$e6 = $body6.GetILProcessor()
function EmitR($e, $op, $arg) {
    $cands = @()
    foreach ($mi in $e.GetType().GetMethods()) {
        if ($mi.Name -ne 'Emit') { continue }
        $ps = $mi.GetParameters()
        if ($ps.Count -eq 2 -and $ps[1].ParameterType.IsInstanceOfType($arg)) { $cands += $mi }
    }
    if ($cands.Count -eq 0) { throw "Emit 重载未找到: $($arg.GetType().FullName)" }
    $best = $cands | Sort-Object { $_.GetParameters()[1].ParameterType } | Select-Object -First 1
    $best.Invoke($e, @($op, $arg)) | Out-Null
}
$lblRet6 = $e6.Create([Mono.Cecil.Cil.OpCodes]::Ret)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldstr, '选择整合包压缩文件')
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldnull)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1)
EmitR $e6 ([Mono.Cecil.Cil.OpCodes]::Newarr) $vtCtor.DeclaringType.GenericArguments[0]
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Dup)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldc_I4_3)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Dup); $e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldc_I4_0); $e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldstr, 'rar'); $e6.Emit([Mono.Cecil.Cil.OpCodes]::Stelem_Ref)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Dup); $e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldc_I4_1); $e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldstr, 'zip'); $e6.Emit([Mono.Cecil.Cil.OpCodes]::Stelem_Ref)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Dup); $e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldc_I4_2); $e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldstr, 'mrpack'); $e6.Emit([Mono.Cecil.Cil.OpCodes]::Stelem_Ref)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldstr, '整合包文件')
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Newobj, $vtCtor)
EmitR $e6 ([Mono.Cecil.Cil.OpCodes]::Stelem_Any) $vtCtor.DeclaringType
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Call, $oneOfImpl)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Newobj, $nulCtor)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Call, $selRef)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Stloc_0)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldloc_0)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Call, $ftuRef)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Stloc_1)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldloc_1)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Brfalse_S, $lblRet6)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Newobj, ($closure6.Methods | Where-Object { $_.Name -eq '.ctor' }))
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Stloc_2)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldloc_2)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldloc_1)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Stfld, $closureField6)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldloc_2)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Ldftn, $closureLambda6)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Newobj, $actCtor)
$e6.Emit([Mono.Cecil.Cil.OpCodes]::Call, $runRef)
$e6.Append($lblRet6)
"P6: ModpackInstall() 本地入口重建"
}

# 4) 写回 (先写临时文件, 确认 PCL 未运行后替换)
$patched = "$work\PCL2_patched.exe"
$rp.Write($patched); $rp.Dispose()
$proc = Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -eq $exe -or $_.ProcessName -in @('PCL2', 'pcl2', 'Plain Craft Launcher 2')
}
if ($proc) { throw "PCL 正在运行 (PID $($proc.Id -join ',')), 请先退出 PCL 再运行本补丁" }
Copy-Item $patched $exe -Force
"完成: $exe 已打补丁 (原文件备份在 $work\original_backup.exe)"
} catch {
    Write-Host ""
    Write-Host "补丁失败: $_" -ForegroundColor Red
} finally {
    Write-Host ""
    Read-Host "按回车键退出"
}
