Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ThreadsModReleaseToolAst {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        ([IO.Path]::GetFullPath($Path)), [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) {
        throw "$Label has PowerShell parse errors."
    }
    return $ast
}

function ConvertTo-ThreadsModReleaseToolAst {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Label
    )

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
        $Text, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) {
        throw "$Label has PowerShell parse errors."
    }
    return $ast
}

function Set-ThreadsModExactTextMutation {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Before,
        [Parameter(Mandatory)][AllowEmptyString()][string]$After,
        [ValidateRange(1, 100)][int]$ExpectedCount = 1,
        [Parameter(Mandatory)][string]$Label
    )

    if ([string]::IsNullOrEmpty($Before)) {
        throw "$Label has an empty mutation anchor."
    }
    $count = [regex]::Matches(
        $Text, [regex]::Escape($Before),
        [Text.RegularExpressions.RegexOptions]::CultureInvariant).Count
    if ($count -ne $ExpectedCount) {
        throw "$Label mutation anchor count drifted: expected $ExpectedCount, observed $count."
    }
    return $Text.Replace($Before, $After)
}

function Test-ThreadsModReleaseTarget {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.Ast]$Target,
        [string]$ScriptName,
        [string]$VariableName
    )

    if (-not [string]::IsNullOrWhiteSpace($VariableName)) {
        return $Target -is [Management.Automation.Language.VariableExpressionAst] `
            -and -not $Target.Splatted `
            -and $Target.VariablePath.UserPath.Equals(
                $VariableName, [StringComparison]::OrdinalIgnoreCase)
    }
    if ([string]::IsNullOrWhiteSpace($ScriptName)) { return $false }
    $literals = @($Target.FindAll({
                param($node)
                if ($node -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
                    return $false
                }
                $value = [string]$node.Value
                return $value.Equals(
                        $ScriptName, [StringComparison]::OrdinalIgnoreCase) `
                    -or $value.EndsWith(
                        "\$ScriptName", [StringComparison]::OrdinalIgnoreCase) `
                    -or $value.EndsWith(
                        "/$ScriptName", [StringComparison]::OrdinalIgnoreCase)
            }, $true))
    return $literals.Count -eq 1
}

function Get-ThreadsModReleaseInvocationParameterNames {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.CommandAst]$Command,
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$CalleeAst,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Command.InvocationOperator -ne [Management.Automation.Language.TokenKind]::Ampersand) {
        throw "$Label must use the ampersand invocation operator."
    }
    if ($null -eq $CalleeAst.ParamBlock) {
        throw "$Label callee has no top-level ParamBlock."
    }

    $calleeNames = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($parameter in @($CalleeAst.ParamBlock.Parameters)) {
        $name = [string]$parameter.Name.VariablePath.UserPath
        if (-not $calleeNames.Add($name)) {
            throw "$Label callee duplicates parameter '$name'."
        }
    }

    $elements = @($Command.CommandElements)
    if (@($elements | Where-Object {
                $_ -is [Management.Automation.Language.VariableExpressionAst] -and $_.Splatted
            }).Count -ne 0) {
        throw "$Label must not use splatting."
    }
    $names = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $index = 1
    while ($index -lt $elements.Count) {
        $parameter = $elements[$index]
        if ($parameter -isnot [Management.Automation.Language.CommandParameterAst]) {
            throw "$Label contains an unsupported positional argument."
        }
        $name = [string]$parameter.ParameterName
        if (-not $seen.Add($name)) {
            throw "$Label duplicates parameter '$name'."
        }
        if (-not $calleeNames.Contains($name)) {
            throw "$Label passes undeclared callee parameter '$name'."
        }
        $names.Add($name)
        $index++

        if ($null -ne $parameter.Argument) { continue }
        if ($index -ge $elements.Count `
                -or $elements[$index] -is [Management.Automation.Language.CommandParameterAst]) {
            throw "$Label parameter '$name' has no argument."
        }
        if ($elements[$index] -is [Management.Automation.Language.VariableExpressionAst] `
                -and $elements[$index].Splatted) {
            throw "$Label must not use splatting."
        }
        $index++
    }
    return @($names)
}

function Assert-ThreadsModReleaseInvocationContract {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$CallerAst,
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$CalleeAst,
        [string]$TargetScriptName,
        [string]$TargetVariableName,
        [Parameter(Mandatory)][object[]]$ExpectedParameterSets,
        [Parameter(Mandatory)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($TargetScriptName) `
            -eq [string]::IsNullOrWhiteSpace($TargetVariableName)) {
        throw "$Label must name exactly one script or variable target."
    }
    $commands = @($CallerAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] `
                    -and $node.CommandElements.Count -gt 0 `
                    -and (Test-ThreadsModReleaseTarget `
                        -Target $node.CommandElements[0] `
                        -ScriptName $TargetScriptName `
                        -VariableName $TargetVariableName)
            }, $true))
    if ($commands.Count -ne $ExpectedParameterSets.Count) {
        throw "$Label invocation count differs from the reviewed contract."
    }

    $proofs = @()
    for ($invocationIndex = 0; $invocationIndex -lt $commands.Count; $invocationIndex++) {
        $observed = @(Get-ThreadsModReleaseInvocationParameterNames `
            -Command $commands[$invocationIndex] -CalleeAst $CalleeAst `
            -Label "$Label invocation $($invocationIndex + 1)")
        $expected = @($ExpectedParameterSets[$invocationIndex].names | ForEach-Object {
                [string]$_
            })
        if ($observed.Count -ne $expected.Count) {
            throw "$Label parameter count differs from the reviewed contract."
        }
        for ($nameIndex = 0; $nameIndex -lt $expected.Count; $nameIndex++) {
            if (-not $observed[$nameIndex].Equals(
                    $expected[$nameIndex], [StringComparison]::Ordinal)) {
                throw "$Label parameter order differs from the reviewed contract."
            }
        }
        $proofs += [pscustomobject]@{
            line = [int]$commands[$invocationIndex].Extent.StartLineNumber
            startOffset = [int]$commands[$invocationIndex].Extent.StartOffset
            parameters = $observed
        }
    }
    return [pscustomobject]@{
        label = $Label
        invocations = $proofs
    }
}

function Test-ThreadsModExactMemberPath {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.Ast]$Expression,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$MemberPath
    )

    $current = $Expression
    $members = [Collections.Generic.List[string]]::new()
    while ($current -is [Management.Automation.Language.MemberExpressionAst]) {
        if ($current.Static `
                -or $current.Member -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
            return $false
        }
        $members.Insert(0, [string]$current.Member.Value)
        $current = $current.Expression
    }
    if ($current -isnot [Management.Automation.Language.VariableExpressionAst] `
            -or $current.Splatted `
            -or -not $current.VariablePath.UserPath.Equals(
                $VariableName, [StringComparison]::Ordinal) `
            -or $members.Count -ne $MemberPath.Count) {
        return $false
    }
    for ($index = 0; $index -lt $MemberPath.Count; $index++) {
        if (-not $members[$index].Equals(
                $MemberPath[$index], [StringComparison]::Ordinal)) {
            return $false
        }
    }
    return $true
}

function Test-ThreadsModEvidenceExpression {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.Ast]$Expression,
        [Parameter(Mandatory)]$Spec
    )

    $current = $Expression
    if ([string]$Spec.cast -eq 'int') {
        if ($current -isnot [Management.Automation.Language.ConvertExpressionAst] `
                -or [string]$current.Type.TypeName -cne 'int') {
            return $false
        }
        $current = $current.Child
    } elseif ([string]$Spec.cast -eq 'bool') {
        if ($current -isnot [Management.Automation.Language.ConvertExpressionAst] `
                -or [string]$current.Type.TypeName -cne 'bool') {
            return $false
        }
        $current = $current.Child
    } elseif ([string]$Spec.cast -eq 'string') {
        if ($current -isnot [Management.Automation.Language.ConvertExpressionAst] `
                -or [string]$current.Type.TypeName -cne 'string') {
            return $false
        }
        $current = $current.Child
    } elseif ($current -is [Management.Automation.Language.ConvertExpressionAst]) {
        return $false
    }

    if ([string]$Spec.mode -eq 'variable') {
        return $current -is [Management.Automation.Language.VariableExpressionAst] `
            -and -not $current.Splatted `
            -and $current.VariablePath.UserPath.Equals(
                [string]$Spec.variable, [StringComparison]::Ordinal)
    }
    if ([string]$Spec.mode -eq 'member') {
        return Test-ThreadsModExactMemberPath `
            -Expression $current -VariableName ([string]$Spec.variable) `
            -MemberPath @($Spec.members | ForEach-Object { [string]$_ })
    }
    if ([string]$Spec.mode -ne 'array-member-count' `
            -or $current -isnot [Management.Automation.Language.MemberExpressionAst] `
            -or $current.Static `
            -or $current.Member -isnot [Management.Automation.Language.StringConstantExpressionAst] `
            -or -not ([string]$current.Member.Value).Equals(
                'Count', [StringComparison]::Ordinal) `
            -or $current.Expression -isnot [Management.Automation.Language.ArrayExpressionAst]) {
        return $false
    }
    $statements = @($current.Expression.SubExpression.Statements)
    if ($statements.Count -ne 1) { return $false }
    $pipelineElements = @($statements[0].PipelineElements)
    if ($pipelineElements.Count -ne 1 `
            -or $pipelineElements[0] -isnot [Management.Automation.Language.CommandExpressionAst]) {
        return $false
    }
    return Test-ThreadsModExactMemberPath `
        -Expression $pipelineElements[0].Expression `
        -VariableName ([string]$Spec.variable) `
        -MemberPath @($Spec.members | ForEach-Object { [string]$_ })
}

function Get-ThreadsModNumericEvidenceComparison {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string]$Label
    )

    $comparisons = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.BinaryExpressionAst] `
                    -and (Test-ThreadsModEvidenceExpression `
                        -Expression $node.Left -Spec $Spec)
            }, $true))
    if ($comparisons.Count -ne 1) {
        throw "$Label must contain exactly one evidence comparison."
    }
    $comparison = $comparisons[0]
    if ($comparison.Operator -ne [Management.Automation.Language.TokenKind]::Ine `
            -or $comparison.Right -isnot [Management.Automation.Language.ConstantExpressionAst]) {
        throw "$Label comparison must use '-ne' and one numeric literal."
    }
    if ($comparison.Right.StaticType -ne [int32] `
            -or $comparison.Right.Extent.Text -cne ([string]$comparison.Right.Value)) {
        throw "$Label comparison must use one canonical Int32 decimal literal."
    }
    return [pscustomobject]@{
        node = $comparison
        literal = [decimal]$comparison.Right.Value
    }
}

function Get-ThreadsModEvidenceLiteral {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string]$Label
    )

    return [decimal](Get-ThreadsModNumericEvidenceComparison `
        -Ast $Ast -Spec $Spec -Label $Label).literal
}

function Get-ThreadsModStringEvidenceComparison {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string]$Label
    )

    $comparisons = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.BinaryExpressionAst] `
                    -and (Test-ThreadsModEvidenceExpression `
                        -Expression $node.Left -Spec $Spec)
            }, $true))
    if ($comparisons.Count -ne 1) {
        throw "$Label must contain exactly one evidence comparison."
    }
    $comparison = $comparisons[0]
    if ($comparison.Operator -ne [Management.Automation.Language.TokenKind]::Ine `
            -or $comparison.Right `
                -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
        throw "$Label comparison must use '-ne' and one string literal."
    }
    return [pscustomobject]@{
        node = $comparison
        literal = [string]$comparison.Right.Value
    }
}

function Get-ThreadsModEvidenceStringLiteral {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string]$Label
    )

    return [string](Get-ThreadsModStringEvidenceComparison `
        -Ast $Ast -Spec $Spec -Label $Label).literal
}

function Get-ThreadsModBooleanEvidenceComparison {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string]$Label
    )

    $guards = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.UnaryExpressionAst] `
                    -and $node.TokenKind -eq [Management.Automation.Language.TokenKind]::Not `
                    -and (Test-ThreadsModEvidenceExpression `
                        -Expression $node.Child -Spec $Spec)
            }, $true))
    if ($guards.Count -ne 1) {
        throw "$Label must contain exactly one fail-closed boolean evidence guard."
    }
    return [pscustomobject]@{
        node = $guards[0]
        literal = $true
    }
}

function Get-ThreadsModClosestAncestor {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.Ast]$Node,
        [Parameter(Mandatory)][type]$Type
    )

    $current = $Node.Parent
    while ($null -ne $current) {
        if ($Type.IsInstanceOfType($current)) { return $current }
        $current = $current.Parent
    }
    return $null
}

function Test-ThreadsModNodeInsideAst {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.Ast]$Node,
        [Parameter(Mandatory)][Management.Automation.Language.Ast]$Container
    )

    return $Node.Extent.StartOffset -ge $Container.Extent.StartOffset `
        -and $Node.Extent.EndOffset -le $Container.Extent.EndOffset
}

function Get-ThreadsModExactFunctionDefinition {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Label
    )

    $functions = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] `
                    -and $node.Name.Equals($Name, [StringComparison]::Ordinal)
            }, $true))
    if ($functions.Count -ne 1) {
        throw "$Label must contain exactly one '$Name' function."
    }
    if ($functions[0].Parent `
            -isnot [Management.Automation.Language.NamedBlockAst] `
            -or $functions[0].Parent.Extent.StartOffset `
                -ne $Ast.EndBlock.Extent.StartOffset) {
        throw "$Label function '$Name' must be declared directly in the live script body."
    }
    return $functions[0]
}

function Test-ThreadsModExactCollectionPipeline {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.PipelineBaseAst]$Pipeline,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$MemberPath,
        [switch]$RequireArrayExpression
    )

    $pipelineElements = @($Pipeline.PipelineElements)
    if ($pipelineElements.Count -ne 1 `
            -or $pipelineElements[0] `
                -isnot [Management.Automation.Language.CommandExpressionAst]) {
        return $false
    }
    $expression = $pipelineElements[0].Expression
    if ($RequireArrayExpression) {
        if ($expression -isnot [Management.Automation.Language.ArrayExpressionAst]) {
            return $false
        }
        $statements = @($expression.SubExpression.Statements)
        if ($statements.Count -ne 1) { return $false }
        $innerElements = @($statements[0].PipelineElements)
        if ($innerElements.Count -ne 1 `
                -or $innerElements[0] `
                    -isnot [Management.Automation.Language.CommandExpressionAst]) {
            return $false
        }
        $expression = $innerElements[0].Expression
    }
    return Test-ThreadsModExactMemberPath `
        -Expression $expression -VariableName $VariableName -MemberPath $MemberPath
}

function Test-ThreadsModExactVersionCondition {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.PipelineBaseAst]$Pipeline,
        [Parameter(Mandatory)][string]$Version
    )

    $elements = @($Pipeline.PipelineElements)
    if ($elements.Count -ne 1 `
            -or $elements[0] -isnot [Management.Automation.Language.CommandExpressionAst] `
            -or $elements[0].Expression `
                -isnot [Management.Automation.Language.BinaryExpressionAst]) {
        return $false
    }
    $comparison = $elements[0].Expression
    $versionSpec = [pscustomobject]@{
        mode = 'member'; cast = 'string'; variable = 'resolution'
        members = @('source', 'versionName')
    }
    return $comparison.Operator -eq [Management.Automation.Language.TokenKind]::Ceq `
        -and (Test-ThreadsModEvidenceExpression `
            -Expression $comparison.Left -Spec $versionSpec) `
        -and $comparison.Right `
            -is [Management.Automation.Language.StringConstantExpressionAst] `
        -and ([string]$comparison.Right.Value).Equals(
            $Version, [StringComparison]::Ordinal)
}

function Get-ThreadsModBridgeWrapperEvidenceLane {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast
    )

    $loops = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ForEachStatementAst] `
                    -and $node.Variable.VariablePath.UserPath.Equals(
                        'contract', [StringComparison]::Ordinal) `
                    -and (Test-ThreadsModExactCollectionPipeline `
                        -Pipeline $node.Condition -VariableName 'resolution' `
                        -MemberPath @('release', 'requiredDexBridgeFlows') `
                        -RequireArrayExpression)
            }, $true))
    if ($loops.Count -ne 1) {
        throw 'Patched-APK evidence must contain exactly one requiredDexBridgeFlows loop.'
    }
    $loop = $loops[0]
    if ($loop.Parent -isnot [Management.Automation.Language.StatementBlockAst] `
            -or $loop.Parent.Parent -isnot [Management.Automation.Language.TryStatementAst] `
            -or $loop.Parent.Parent.Body.Extent.StartOffset `
                -ne $loop.Parent.Extent.StartOffset `
            -or $loop.Parent.Parent.Parent `
                -isnot [Management.Automation.Language.NamedBlockAst] `
            -or $loop.Parent.Parent.Parent.Extent.StartOffset `
                -ne $Ast.EndBlock.Extent.StartOffset) {
        throw 'Patched-APK requiredDexBridgeFlows loop escaped the live top-level validation try body.'
    }
    $versionBranches = @($loop.Body.Statements | Where-Object {
            $_ -is [Management.Automation.Language.IfStatementAst] `
                -and $_.Clauses.Count -eq 2 `
                -and (Test-ThreadsModExactVersionCondition `
                    -Pipeline $_.Clauses[0].Item1 -Version '444.0.0.45.85') `
                -and (Test-ThreadsModExactVersionCondition `
                    -Pipeline $_.Clauses[1].Item1 -Version '415.0.0.26.77') `
                -and $null -ne $_.ElseClause
        })
    if ($versionBranches.Count -ne 1) {
        throw 'Patched-APK bridge evidence must have one exact 444-current / 415-legacy version branch.'
    }
    $versionBranch = $versionBranches[0]
    $currentInner = @($versionBranch.Clauses[0].Item2.Statements | Where-Object {
            $_ -is [Management.Automation.Language.IfStatementAst]
        })
    $legacyInner = @($versionBranch.Clauses[1].Item2.Statements | Where-Object {
            $_ -is [Management.Automation.Language.IfStatementAst]
        })
    if ($currentInner.Count -ne 1 -or $legacyInner.Count -ne 1 `
            -or @($versionBranch.Clauses[0].Item2.Statements).Count -ne 1 `
            -or @($versionBranch.Clauses[1].Item2.Statements).Count -ne 2 `
            -or @($versionBranch.ElseClause.Statements).Count -ne 1 `
            -or $versionBranch.ElseClause.Statements[0] `
                -isnot [Management.Automation.Language.ThrowStatementAst]) {
        throw 'Patched-APK bridge version lanes must each contain one exact evidence guard.'
    }
    $legacyAssignments = @($versionBranch.Clauses[1].Item2.Statements | Where-Object {
            $_ -is [Management.Automation.Language.AssignmentStatementAst] `
                -and $_.Left -is [Management.Automation.Language.VariableExpressionAst] `
                -and $_.Left.VariablePath.UserPath.Equals(
                    'legacyBridgeResult', [StringComparison]::Ordinal) `
                -and $_.Right -is [Management.Automation.Language.CommandExpressionAst] `
                -and $_.Right.Expression `
                    -is [Management.Automation.Language.VariableExpressionAst] `
                -and $_.Right.Expression.VariablePath.UserPath.Equals(
                    'bridgeResult', [StringComparison]::Ordinal)
        })
    if ($legacyAssignments.Count -ne 1) {
        throw 'Patched-APK legacy bridge lane must bind legacyBridgeResult once from bridgeResult.'
    }
    if ($legacyAssignments[0].Extent.StartOffset `
            -ge $legacyInner[0].Extent.StartOffset) {
        throw 'Patched-APK legacy bridge alias must be bound before its evidence guard.'
    }
    return [pscustomobject]@{
        loop = $loop
        body = $loop.Body
        version = $versionBranch
        current = $currentInner[0]
        legacy = $legacyInner[0]
    }
}

function Assert-ThreadsModEvidenceNodesInFunction {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)][string]$FunctionName,
        [Parameter(Mandatory)][object[]]$Nodes,
        [Parameter(Mandatory)][string]$Label
    )

    $function = Get-ThreadsModExactFunctionDefinition `
        -Ast $Ast -Name $FunctionName -Label $Label
    $guards = [Collections.Generic.HashSet[int]]::new()
    foreach ($node in $Nodes) {
        $owner = Get-ThreadsModClosestAncestor `
            -Node $node -Type ([Management.Automation.Language.FunctionDefinitionAst])
        $guard = Get-ThreadsModClosestAncestor `
            -Node $node -Type ([Management.Automation.Language.IfStatementAst])
        if ($null -eq $owner -or $null -eq $guard `
                -or $owner.Extent.StartOffset -ne $function.Extent.StartOffset `
                -or $guard.Parent `
                    -isnot [Management.Automation.Language.NamedBlockAst] `
                -or $guard.Parent.Extent.StartOffset `
                    -ne $function.Body.EndBlock.Extent.StartOffset `
                -or -not (Test-ThreadsModExactFailClosedEvidenceGuard `
                    -Node $node -Guard $guard)) {
            throw "$Label evidence escaped '$FunctionName'."
        }
        $null = $guards.Add([int]$guard.Extent.StartOffset)
    }
    if ($guards.Count -ne 1) {
        throw "$Label evidence must share one fail-closed guard in '$FunctionName'."
    }
    return [pscustomobject]@{
        function = $FunctionName
        guardOffset = @($guards)[0]
    }
}

function Test-ThreadsModExactFailClosedEvidenceGuard {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.Ast]$Node,
        [Parameter(Mandatory)][Management.Automation.Language.IfStatementAst]$Guard
    )

    if ($Guard.Clauses.Count -ne 1 -or $null -ne $Guard.ElseClause) {
        return $false
    }
    $condition = $Guard.Clauses[0].Item1
    if (-not (Test-ThreadsModNodeInsideAst -Node $Node -Container $condition)) {
        return $false
    }
    $elements = @($condition.PipelineElements)
    if ($elements.Count -ne 1 `
            -or $elements[0] -isnot [Management.Automation.Language.CommandExpressionAst]) {
        return $false
    }
    $root = $elements[0].Expression
    $current = $Node
    while ($current.Extent.StartOffset -ne $root.Extent.StartOffset `
            -or $current.Extent.EndOffset -ne $root.Extent.EndOffset) {
        $parent = $current.Parent
        if ($null -eq $parent `
                -or $parent -isnot [Management.Automation.Language.BinaryExpressionAst] `
                -or $parent.Operator -ne [Management.Automation.Language.TokenKind]::Or) {
            return $false
        }
        $current = $parent
    }
    $statements = @($Guard.Clauses[0].Item2.Statements)
    return $statements.Count -eq 1 `
        -and $statements[0] -is [Management.Automation.Language.ThrowStatementAst]
}

function Assert-ThreadsModReleaseEvidenceContract {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$ReleaseWrapperAst,
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$FixtureHarnessAst,
        [Parameter(Mandatory)][ValidateRange(1, 100000)][int]$ReviewedFixtureCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedTerminalRoutes,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedCurrentTerminalRoutes,
        [Parameter(Mandatory)][ValidateRange(0, 1000)][int]$ReviewedCurrentPacedNextPosts,
        [Parameter(Mandatory)][ValidateSet('single-target')][string]$ReviewedCurrentOwnerMode,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedPrepareModelInvokeCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedPassivePreflightInvokeCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedCacheLookupInvokeCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedCacheFactoryInvokeCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedCachePlaceholderInvokeCount
    )

    $currentMetrics = [ordered]@{
        reviewedTerminalRoutes = $ReviewedCurrentTerminalRoutes
        pacedNextPosts = $ReviewedCurrentPacedNextPosts
        terminalCatchRoutes = 1
        startedLatchWrites = 1
        statusCalls = 1
        failureRoutes = 1
        completionSaveCalls = 1
        completionQuarantineBranches = 1
        ownershipReleaseCalls = 1
        successRecordCalls = 1
        waitingClearWrites = 1
    }
    $contracts = @()
    foreach ($entry in $currentMetrics.GetEnumerator()) {
        $path = @('callerCallbackEffectTopology', 'automatic', [string]$entry.Key)
        $contracts += [pscustomobject]@{
            id = 'current.' + [string]$entry.Key
            reviewed = [int]$entry.Value
            wrapper = [pscustomobject]@{
                mode = 'member'; cast = 'int'; variable = 'bridgeResult'; members = $path
            }
            harness = [pscustomobject]@{
                mode = 'member'; cast = 'int'; variable = 'CurrentResult'; members = $path
            }
        }
    }
    $sharedBridgeMetrics = @(
        [pscustomobject]@{
            id = 'rawPrepareModel'
            path = @('rawCalls', 'prepareModel')
            reviewed = $ReviewedPrepareModelInvokeCount
        },
        [pscustomobject]@{
            id = 'rawPassivePreflight'
            path = @('rawCalls', 'passivePreflight')
            reviewed = $ReviewedPassivePreflightInvokeCount
        },
        [pscustomobject]@{
            id = 'passivePreflightDefinition'
            path = @('definitions', 'passivePreflight')
            reviewed = 1
        },
        [pscustomobject]@{
            id = 'automaticPassivePreflight'
            path = @('callerProvenance', 'automatic', 'passivePreflight')
            reviewed = 1
        },
        [pscustomobject]@{
            id = 'manualPassivePreflight'
            path = @('callerProvenance', 'manual', 'passivePreflight')
            reviewed = 0
        },
        [pscustomobject]@{
            id = 'bridgePrepareModel'
            path = @('callerProvenance', 'bridge', 'prepareModel')
            reviewed = $ReviewedPrepareModelInvokeCount
        },
        [pscustomobject]@{
            id = 'bridgePassivePreflight'
            path = @('callerProvenance', 'bridge', 'passivePreflight')
            reviewed = 0
        },
        [pscustomobject]@{
            id = 'otherPassivePreflight'
            path = @('callerProvenance', 'other', 'passivePreflight')
            reviewed = 0
        },
        [pscustomobject]@{
            id = 'cacheLookup'
            path = @('privateSeamProvenance', 'cacheLookup')
            reviewed = $ReviewedCacheLookupInvokeCount
        },
        [pscustomobject]@{
            id = 'cacheFactory'
            path = @('privateSeamProvenance', 'cacheFactory')
            reviewed = $ReviewedCacheFactoryInvokeCount
        },
        [pscustomobject]@{
            id = 'cachePlaceholder'
            path = @('privateSeamProvenance', 'cachePlaceholder')
            reviewed = $ReviewedCachePlaceholderInvokeCount
        }
    )
    foreach ($entry in $sharedBridgeMetrics) {
        $contracts += [pscustomobject]@{
            id = 'sharedBridge.' + [string]$entry.id
            reviewed = [int]$entry.reviewed
            wrapper = [pscustomobject]@{
                mode = 'member'; cast = 'int'; variable = 'bridgeResult'
                members = @($entry.path)
            }
            harness = [pscustomobject]@{
                mode = 'member'; cast = 'int'; variable = 'CurrentResult'
                members = @($entry.path)
            }
        }
    }
    $contracts += [pscustomobject]@{
        id = 'expectedFixtureCount'
        reviewed = $ReviewedFixtureCount
        wrapper = [pscustomobject]@{
            mode = 'member'; cast = 'int'; variable = 'dexBridgeFlowFixtureResult'
            members = @('expectedFixtureCount')
        }
        harness = [pscustomobject]@{
            mode = 'variable'; cast = 'int'; variable = 'expectedFixtureCount'; members = @()
        }
    }
    $contracts += [pscustomobject]@{
        id = 'fixtures.Count'
        reviewed = $ReviewedFixtureCount
        wrapper = [pscustomobject]@{
            mode = 'array-member-count'; cast = 'none'
            variable = 'dexBridgeFlowFixtureResult'; members = @('fixtures')
        }
        harness = [pscustomobject]@{
            mode = 'member'; cast = 'none'; variable = 'results'; members = @('Count')
        }
    }

    $proofs = @()
    $wrapperCurrentNodes = @{}
    $harnessCurrentNodes = @{}
    $wrapperSharedBridgeNodes = @{}
    $harnessSharedBridgeNodes = @{}
    foreach ($contract in $contracts) {
        $wrapperComparison = Get-ThreadsModNumericEvidenceComparison `
            -Ast $ReleaseWrapperAst -Spec $contract.wrapper `
            -Label "Release wrapper $($contract.id)"
        $harnessComparison = Get-ThreadsModNumericEvidenceComparison `
            -Ast $FixtureHarnessAst -Spec $contract.harness `
            -Label "Positive fixture harness $($contract.id)"
        if ($wrapperComparison.literal -ne $harnessComparison.literal) {
            throw "Release wrapper and fixture harness disagree on $($contract.id)."
        }
        if ($wrapperComparison.literal -ne [decimal]$contract.reviewed) {
            throw "Release evidence $($contract.id) differs from the reviewed literal."
        }
        if ([string]$contract.id -like 'current.*') {
            $metric = ([string]$contract.id).Substring('current.'.Length)
            $wrapperCurrentNodes[$metric] = $wrapperComparison.node
            $harnessCurrentNodes[$metric] = $harnessComparison.node
        } elseif ([string]$contract.id -like 'sharedBridge.*') {
            $metric = ([string]$contract.id).Substring('sharedBridge.'.Length)
            $wrapperSharedBridgeNodes[$metric] = $wrapperComparison.node
            $harnessSharedBridgeNodes[$metric] = $harnessComparison.node
        }
        $proofs += [pscustomobject]@{
            id = [string]$contract.id
            literal = [int]$wrapperComparison.literal
        }
    }

    $ownerSpecWrapper = [pscustomobject]@{
        mode = 'member'; cast = 'string'; variable = 'bridgeResult'
        members = @('callerProvenance', 'automatic', 'ownerMode')
    }
    $ownerSpecHarness = [pscustomobject]@{
        mode = 'member'; cast = 'string'; variable = 'CurrentResult'
        members = @('callerProvenance', 'automatic', 'ownerMode')
    }
    $wrapperOwner = Get-ThreadsModStringEvidenceComparison `
        -Ast $ReleaseWrapperAst -Spec $ownerSpecWrapper `
        -Label 'Release wrapper current.ownerMode'
    $harnessOwner = Get-ThreadsModStringEvidenceComparison `
        -Ast $FixtureHarnessAst -Spec $ownerSpecHarness `
        -Label 'Positive fixture harness current.ownerMode'
    if ($wrapperOwner.literal -cne $harnessOwner.literal `
            -or $wrapperOwner.literal -cne $ReviewedCurrentOwnerMode) {
        throw 'Release current owner mode differs from the generated-Smali fixture or reviewed resolution literal.'
    }
    $proofs += [pscustomobject]@{
        id = 'current.ownerMode'
        literal = [string]$wrapperOwner.literal
    }

    $currentChecks = @(
        'immutableTargetFlow',
        'schedulerEnqueueAcceptance',
        'uncertainMutationQuarantine',
        'callerCallbackEffectTopology'
    )
    $sharedBridgeChecks = @(
        'passiveNativePreflight',
        'passiveMatchFailClosed'
    )
    $wrapperBooleanNodes = @{}
    $harnessBooleanNodes = @{}
    foreach ($check in $currentChecks) {
        $wrapperGuard = Get-ThreadsModBooleanEvidenceComparison `
            -Ast $ReleaseWrapperAst -Spec ([pscustomobject]@{
                mode = 'member'; cast = 'bool'; variable = 'bridgeResult'
                members = @('checks', $check)
            }) -Label "Release wrapper current.checks.$check"
        $harnessGuard = Get-ThreadsModBooleanEvidenceComparison `
            -Ast $FixtureHarnessAst -Spec ([pscustomobject]@{
                mode = 'member'; cast = 'bool'; variable = 'CurrentResult'
                members = @('checks', $check)
            }) -Label "Positive fixture harness current.checks.$check"
        if (-not $wrapperGuard.literal -or -not $harnessGuard.literal) {
            throw "Release current boolean evidence '$check' is not fail-closed true."
        }
        $wrapperBooleanNodes[$check] = $wrapperGuard.node
        $harnessBooleanNodes[$check] = $harnessGuard.node
        $proofs += [pscustomobject]@{
            id = 'current.checks.' + $check
            literal = $true
        }
    }
    $wrapperSharedBridgeBooleanNodes = @{}
    $harnessSharedBridgeBooleanNodes = @{}
    foreach ($check in $sharedBridgeChecks) {
        $wrapperGuard = Get-ThreadsModBooleanEvidenceComparison `
            -Ast $ReleaseWrapperAst -Spec ([pscustomobject]@{
                mode = 'member'; cast = 'bool'; variable = 'bridgeResult'
                members = @('checks', $check)
            }) -Label "Release wrapper sharedBridge.checks.$check"
        $harnessGuard = Get-ThreadsModBooleanEvidenceComparison `
            -Ast $FixtureHarnessAst -Spec ([pscustomobject]@{
                mode = 'member'; cast = 'bool'; variable = 'CurrentResult'
                members = @('checks', $check)
            }) -Label "Positive fixture harness sharedBridge.checks.$check"
        if (-not $wrapperGuard.literal -or -not $harnessGuard.literal) {
            throw "Release shared bridge boolean evidence '$check' is not fail-closed true."
        }
        $wrapperSharedBridgeBooleanNodes[$check] = $wrapperGuard.node
        $harnessSharedBridgeBooleanNodes[$check] = $harnessGuard.node
        $proofs += [pscustomobject]@{
            id = 'sharedBridge.checks.' + $check
            literal = $true
        }
    }

    $legacyTerminalPath = @(
        'callerCallbackEffectTopology', 'automatic', 'reviewedTerminalRoutes')
    $legacyPacedPath = @(
        'callerCallbackEffectTopology', 'automatic', 'pacedNextPosts')
    $legacyWrapperTerminal = Get-ThreadsModNumericEvidenceComparison `
        -Ast $ReleaseWrapperAst -Spec ([pscustomobject]@{
            mode = 'member'; cast = 'int'; variable = 'legacyBridgeResult'
            members = $legacyTerminalPath
        }) -Label 'Release wrapper legacy reviewedTerminalRoutes'
    $legacyHarnessTerminal = Get-ThreadsModNumericEvidenceComparison `
        -Ast $FixtureHarnessAst -Spec ([pscustomobject]@{
            mode = 'member'; cast = 'int'; variable = 'Result'
            members = $legacyTerminalPath
        }) -Label 'Legacy fixture reviewedTerminalRoutes'
    $legacyWrapperPaced = Get-ThreadsModNumericEvidenceComparison `
        -Ast $ReleaseWrapperAst -Spec ([pscustomobject]@{
            mode = 'member'; cast = 'int'; variable = 'legacyBridgeResult'
            members = $legacyPacedPath
        }) -Label 'Release wrapper legacy pacedNextPosts'
    $legacyHarnessPaced = Get-ThreadsModNumericEvidenceComparison `
        -Ast $FixtureHarnessAst -Spec ([pscustomobject]@{
            mode = 'member'; cast = 'int'; variable = 'Result'
            members = $legacyPacedPath
        }) -Label 'Legacy fixture pacedNextPosts'
    $legacyOwnerPath = @('callerProvenance', 'automatic', 'ownerMode')
    $legacyWrapperOwner = Get-ThreadsModStringEvidenceComparison `
        -Ast $ReleaseWrapperAst -Spec ([pscustomobject]@{
            mode = 'member'; cast = 'string'; variable = 'legacyBridgeResult'
            members = $legacyOwnerPath
        }) -Label 'Release wrapper legacy ownerMode'
    $legacyHarnessOwner = Get-ThreadsModStringEvidenceComparison `
        -Ast $FixtureHarnessAst -Spec ([pscustomobject]@{
            mode = 'member'; cast = 'string'; variable = 'Result'
            members = $legacyOwnerPath
        }) -Label 'Legacy fixture ownerMode'
    if ($legacyWrapperTerminal.literal -ne $legacyHarnessTerminal.literal `
            -or $legacyWrapperTerminal.literal -ne [decimal]$ReviewedTerminalRoutes `
            -or $legacyWrapperPaced.literal -ne $legacyHarnessPaced.literal `
            -or $legacyWrapperPaced.literal -ne 1 `
            -or $legacyWrapperOwner.literal -cne $legacyHarnessOwner.literal `
            -or $legacyWrapperOwner.literal -cne 'legacy-batch') {
        throw 'Legacy bridge-flow wrapper and regression fixture differ from reviewed auxiliary evidence.'
    }
    $legacyHarnessSharedNodes = @{}
    foreach ($metric in @($currentMetrics.Keys | Where-Object {
                $_ -notin @('reviewedTerminalRoutes', 'pacedNextPosts')
            })) {
        $legacyMetric = Get-ThreadsModNumericEvidenceComparison `
            -Ast $FixtureHarnessAst -Spec ([pscustomobject]@{
                mode = 'member'; cast = 'int'; variable = 'Result'
                members = @(
                    'callerCallbackEffectTopology', 'automatic', [string]$metric)
            }) -Label "Legacy fixture $metric"
        if ($legacyMetric.literal -ne $wrapperCurrentNodes[[string]$metric].Right.Value `
                -or $legacyMetric.literal -ne 1) {
            throw "Legacy bridge-flow fixture shared metric '$metric' differs from reviewed common evidence."
        }
        $legacyHarnessSharedNodes[[string]$metric] = $legacyMetric.node
        $proofs += [pscustomobject]@{
            id = 'legacy.' + [string]$metric
            literal = [int]$legacyMetric.literal
        }
    }
    $legacyHarnessBridgeNodes = @{}
    foreach ($entry in $sharedBridgeMetrics) {
        $legacyMetric = Get-ThreadsModNumericEvidenceComparison `
            -Ast $FixtureHarnessAst -Spec ([pscustomobject]@{
                mode = 'member'; cast = 'int'; variable = 'Result'
                members = @($entry.path)
            }) -Label "Legacy fixture sharedBridge.$($entry.id)"
        if ($legacyMetric.literal -ne [decimal]$entry.reviewed `
                -or $legacyMetric.literal `
                    -ne $wrapperSharedBridgeNodes[[string]$entry.id].Right.Value) {
            throw "Legacy bridge-flow fixture shared bridge metric '$($entry.id)' differs from reviewed evidence."
        }
        $legacyHarnessBridgeNodes[[string]$entry.id] = $legacyMetric.node
        $proofs += [pscustomobject]@{
            id = 'legacy.sharedBridge.' + [string]$entry.id
            literal = [int]$legacyMetric.literal
        }
    }
    $legacyHarnessSharedBridgeBooleanNodes = @{}
    foreach ($check in $sharedBridgeChecks) {
        $legacyGuard = Get-ThreadsModBooleanEvidenceComparison `
            -Ast $FixtureHarnessAst -Spec ([pscustomobject]@{
                mode = 'member'; cast = 'bool'; variable = 'Result'
                members = @('checks', $check)
            }) -Label "Legacy fixture sharedBridge.checks.$check"
        if (-not $legacyGuard.literal) {
            throw "Legacy shared bridge boolean evidence '$check' is not fail-closed true."
        }
        $legacyHarnessSharedBridgeBooleanNodes[$check] = $legacyGuard.node
        $proofs += [pscustomobject]@{
            id = 'legacy.sharedBridge.checks.' + $check
            literal = $true
        }
    }

    $wrapperLane = Get-ThreadsModBridgeWrapperEvidenceLane -Ast $ReleaseWrapperAst
    $currentSpecificWrapperNodes = @(
        $wrapperOwner.node,
        $wrapperCurrentNodes['reviewedTerminalRoutes'],
        $wrapperCurrentNodes['pacedNextPosts'])
    foreach ($node in $currentSpecificWrapperNodes) {
        $guard = Get-ThreadsModClosestAncestor `
            -Node $node -Type ([Management.Automation.Language.IfStatementAst])
        if ($null -eq $guard `
                -or $guard.Extent.StartOffset -ne $wrapperLane.current.Extent.StartOffset `
                -or -not (Test-ThreadsModExactFailClosedEvidenceGuard `
                    -Node $node -Guard $guard)) {
            throw 'Current bridge evidence is not confined to the exact 444 version lane.'
        }
    }
    foreach ($node in @(
            $legacyWrapperOwner.node,
            $legacyWrapperTerminal.node,
            $legacyWrapperPaced.node)) {
        $guard = Get-ThreadsModClosestAncestor `
            -Node $node -Type ([Management.Automation.Language.IfStatementAst])
        if ($null -eq $guard `
                -or $guard.Extent.StartOffset -ne $wrapperLane.legacy.Extent.StartOffset `
                -or -not (Test-ThreadsModExactFailClosedEvidenceGuard `
                    -Node $node -Guard $guard)) {
            throw 'Legacy bridge evidence is not confined to the exact 415 version lane.'
        }
    }
    $sharedWrapperNodes = @()
    foreach ($metric in @($currentMetrics.Keys | Where-Object {
                $_ -notin @('reviewedTerminalRoutes', 'pacedNextPosts')
            })) {
        $sharedWrapperNodes += $wrapperCurrentNodes[[string]$metric]
    }
    foreach ($check in $currentChecks) {
        $sharedWrapperNodes += $wrapperBooleanNodes[$check]
    }
    foreach ($entry in $sharedBridgeMetrics) {
        $sharedWrapperNodes += $wrapperSharedBridgeNodes[[string]$entry.id]
    }
    foreach ($check in $sharedBridgeChecks) {
        $sharedWrapperNodes += $wrapperSharedBridgeBooleanNodes[$check]
    }
    $sharedGuards = [Collections.Generic.HashSet[int]]::new()
    foreach ($node in $sharedWrapperNodes) {
        $guard = Get-ThreadsModClosestAncestor `
            -Node $node -Type ([Management.Automation.Language.IfStatementAst])
        if ($null -eq $guard `
                -or $guard.Parent -isnot [Management.Automation.Language.StatementBlockAst] `
                -or $guard.Parent.Extent.StartOffset -ne $wrapperLane.body.Extent.StartOffset `
                -or $guard.Extent.StartOffset -le $wrapperLane.version.Extent.EndOffset `
                -or -not (Test-ThreadsModExactFailClosedEvidenceGuard `
                    -Node $node -Guard $guard)) {
            throw 'Shared bridge evidence must execute after the exact current/legacy branch in the common loop lane.'
        }
        $null = $sharedGuards.Add([int]$guard.Extent.StartOffset)
    }
    if ($sharedGuards.Count -ne 1) {
        throw 'Shared current bridge metrics and booleans must remain in one common fail-closed guard.'
    }

    $currentHarnessNodes = @($harnessOwner.node)
    foreach ($metric in $currentMetrics.Keys) {
        $currentHarnessNodes += $harnessCurrentNodes[[string]$metric]
    }
    foreach ($check in $currentChecks) {
        $currentHarnessNodes += $harnessBooleanNodes[$check]
    }
    foreach ($entry in $sharedBridgeMetrics) {
        $currentHarnessNodes += $harnessSharedBridgeNodes[[string]$entry.id]
    }
    foreach ($check in $sharedBridgeChecks) {
        $currentHarnessNodes += $harnessSharedBridgeBooleanNodes[$check]
    }
    $currentHarnessAncestry = Assert-ThreadsModEvidenceNodesInFunction `
        -Ast $FixtureHarnessAst `
        -FunctionName 'Assert-SingleTargetPositiveEvidence' `
        -Nodes $currentHarnessNodes -Label 'Current bridge fixture'
    $legacyHarnessNodes = @(
        $legacyHarnessOwner.node,
        $legacyHarnessTerminal.node,
        $legacyHarnessPaced.node)
    foreach ($metric in $legacyHarnessSharedNodes.Keys) {
        $legacyHarnessNodes += $legacyHarnessSharedNodes[$metric]
    }
    foreach ($metric in $legacyHarnessBridgeNodes.Keys) {
        $legacyHarnessNodes += $legacyHarnessBridgeNodes[$metric]
    }
    foreach ($check in $sharedBridgeChecks) {
        $legacyHarnessNodes += $legacyHarnessSharedBridgeBooleanNodes[$check]
    }
    $legacyHarnessAncestry = Assert-ThreadsModEvidenceNodesInFunction `
        -Ast $FixtureHarnessAst -FunctionName 'Assert-PositiveEvidence' `
        -Nodes $legacyHarnessNodes -Label 'Legacy bridge fixture'

    $proofs += [pscustomobject]@{
        id = 'legacy.reviewedTerminalRoutes'
        literal = [int]$legacyWrapperTerminal.literal
    }
    $proofs += [pscustomobject]@{
        id = 'legacy.pacedNextPosts'
        literal = [int]$legacyWrapperPaced.literal
    }
    $proofs += [pscustomobject]@{
        id = 'legacy.ownerMode'
        literal = [string]$legacyWrapperOwner.literal
    }
    return [pscustomobject]@{
        status = 'passed'
        expectations = $proofs
        ancestry = [pscustomobject]@{
            wrapper = '444-current / 415-legacy / shared-post-branch'
            currentHarness = $currentHarnessAncestry
            legacyHarness = $legacyHarnessAncestry
        }
    }
}

function Assert-ThreadsModReportPermalinkEvidenceContract {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$ReleaseWrapperAst,
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$FixtureHarnessAst,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedFixtureCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedInspectorArgumentCount
    )

    $contracts = @(
        [pscustomobject]@{
            id = 'reportPermalink.expectedFixtureCount'
            reviewed = $ReviewedFixtureCount
            wrapper = [pscustomobject]@{
                mode = 'member'; cast = 'int'
                variable = 'dexReportPermalinkFlowFixtureResult'
                members = @('expectedFixtureCount')
            }
            harness = [pscustomobject]@{
                mode = 'variable'; cast = 'int'; variable = 'expectedFixtureCount'
                members = @()
            }
        },
        [pscustomobject]@{
            id = 'reportPermalink.fixtures.Count'
            reviewed = $ReviewedFixtureCount
            wrapper = [pscustomobject]@{
                mode = 'array-member-count'; cast = 'none'
                variable = 'dexReportPermalinkFlowFixtureResult'
                members = @('fixtures')
            }
            harness = [pscustomobject]@{
                mode = 'member'; cast = 'none'; variable = 'results'
                members = @('Count')
            }
        },
        [pscustomobject]@{
            id = 'reportPermalink.inspectorArgumentCount'
            reviewed = $ReviewedInspectorArgumentCount
            wrapper = [pscustomobject]@{
                mode = 'member'; cast = 'int'
                variable = 'dexReportPermalinkFlowFixtureResult'
                members = @('inspectorArgumentCount')
            }
            harness = [pscustomobject]@{
                mode = 'variable'; cast = 'int'; variable = 'inspectorArgumentCount'
                members = @()
            }
        },
        [pscustomobject]@{
            id = 'reportPermalink.rowControl.ufiButtonDefaultMask'
            reviewed = 63232
            wrapper = [pscustomobject]@{
                mode = 'member'; cast = 'int'
                variable = 'dexReportPermalinkFlow'
                members = @('rowControl', 'ufiButtonDefaultMask')
            }
            harness = [pscustomobject]@{
                mode = 'member'; cast = 'int'; variable = 'positiveResult'
                members = @('rowControl', 'ufiButtonDefaultMask')
            }
        }
    )
    $proofs = @()
    foreach ($contract in $contracts) {
        $wrapper = Get-ThreadsModEvidenceLiteral `
            -Ast $ReleaseWrapperAst -Spec $contract.wrapper `
            -Label "Release wrapper $($contract.id)"
        $harness = Get-ThreadsModEvidenceLiteral `
            -Ast $FixtureHarnessAst -Spec $contract.harness `
            -Label "Report-permalink fixture harness $($contract.id)"
        if ($wrapper -ne $harness -or $wrapper -ne [decimal]$contract.reviewed) {
            throw "Report-permalink wrapper and fixture evidence disagree on $($contract.id)."
        }
        $proofs += [pscustomobject]@{ id = [string]$contract.id; literal = [int]$wrapper }
    }
    $booleanContracts = @(
        [pscustomobject]@{
            id = 'reportPermalink.checks.rowDecoratedModifierFlow'
            wrapper = [pscustomobject]@{
                mode = 'member'; cast = 'bool'; variable = 'dexReportPermalinkFlow'
                members = @('checks', 'rowDecoratedModifierFlow')
            }
            harness = [pscustomobject]@{
                mode = 'member'; cast = 'bool'; variable = 'positiveResult'
                members = @('checks', 'rowDecoratedModifierFlow')
            }
        },
        [pscustomobject]@{
            id = 'reportPermalink.checks.rowUfiDefaultMaskExact'
            wrapper = [pscustomobject]@{
                mode = 'member'; cast = 'bool'; variable = 'dexReportPermalinkFlow'
                members = @('checks', 'rowUfiDefaultMaskExact')
            }
            harness = [pscustomobject]@{
                mode = 'member'; cast = 'bool'; variable = 'positiveResult'
                members = @('checks', 'rowUfiDefaultMaskExact')
            }
        }
    )
    foreach ($contract in $booleanContracts) {
        $wrapper = Get-ThreadsModBooleanEvidenceComparison `
            -Ast $ReleaseWrapperAst -Spec $contract.wrapper `
            -Label "Release wrapper $($contract.id)"
        $harness = Get-ThreadsModBooleanEvidenceComparison `
            -Ast $FixtureHarnessAst -Spec $contract.harness `
            -Label "Report-permalink fixture harness $($contract.id)"
        if (-not [bool]$wrapper.literal -or -not [bool]$harness.literal) {
            throw "Report-permalink wrapper and fixture evidence disagree on $($contract.id)."
        }
        $proofs += [pscustomobject]@{ id = [string]$contract.id; literal = $true }
    }
    return [pscustomobject]@{ status = 'passed'; expectations = $proofs }
}

function Assert-ThreadsModProxyBootstrapEvidenceContract {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$ReleaseWrapperAst,
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$FixtureHarnessAst,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedFixtureCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedInspectorArgumentCount
    )

    $contracts = @(
        [pscustomobject]@{
            id = 'proxyBootstrap.expectedFixtureCount'
            reviewed = $ReviewedFixtureCount
            wrapper = [pscustomobject]@{
                mode = 'member'; cast = 'int'
                variable = 'dexProxyBootstrapFlowFixtureResult'
                members = @('expectedFixtureCount')
            }
            harness = [pscustomobject]@{
                mode = 'variable'; cast = 'int'; variable = 'expectedFixtureCount'
                members = @()
            }
        },
        [pscustomobject]@{
            id = 'proxyBootstrap.fixtures.Count'
            reviewed = $ReviewedFixtureCount
            wrapper = [pscustomobject]@{
                mode = 'array-member-count'; cast = 'none'
                variable = 'dexProxyBootstrapFlowFixtureResult'
                members = @('fixtures')
            }
            harness = [pscustomobject]@{
                mode = 'member'; cast = 'none'; variable = 'results'
                members = @('Count')
            }
        },
        [pscustomobject]@{
            id = 'proxyBootstrap.inspectorArgumentCount'
            reviewed = $ReviewedInspectorArgumentCount
            wrapper = [pscustomobject]@{
                mode = 'member'; cast = 'int'
                variable = 'dexProxyBootstrapFlowFixtureResult'
                members = @('inspectorArgumentCount')
            }
            harness = [pscustomobject]@{
                mode = 'variable'; cast = 'int'; variable = 'inspectorArgumentCount'
                members = @()
            }
        }
    )
    $proofs = @()
    foreach ($contract in $contracts) {
        $wrapper = Get-ThreadsModEvidenceLiteral `
            -Ast $ReleaseWrapperAst -Spec $contract.wrapper `
            -Label "Release wrapper $($contract.id)"
        $harness = Get-ThreadsModEvidenceLiteral `
            -Ast $FixtureHarnessAst -Spec $contract.harness `
            -Label "Proxy-bootstrap fixture harness $($contract.id)"
        if ($wrapper -ne $harness -or $wrapper -ne [decimal]$contract.reviewed) {
            throw "Proxy-bootstrap wrapper and fixture evidence disagree on $($contract.id)."
        }
        $proofs += [pscustomobject]@{
            id = [string]$contract.id
            literal = [int]$wrapper
        }
    }
    return [pscustomobject]@{ status = 'passed'; expectations = $proofs }
}

function Assert-ThreadsModDexBridgeInspectorArgumentTextContract {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedArgumentCount,
        [Parameter(Mandatory)][string]$Label
    )

    $guards = [regex]::Matches(
        $Text,
        '(?m)^\s*if\s*\(\s*args\.length\s*!=\s*(?<count>[0-9]+)\s*\)\s*\{')
    if ($guards.Count -ne 1) {
        throw "$Label must contain exactly one literal args.length guard."
    }
    $observed = 0
    if (-not [int]::TryParse(
            [string]$guards[0].Groups['count'].Value,
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$observed)) {
        throw "$Label args.length guard is not a bounded integer literal."
    }
    if ($observed -ne $ReviewedArgumentCount) {
        throw "$Label args.length guard differs from the reviewed resolution count."
    }
    return [pscustomobject]@{
        status = 'passed'
        argumentCount = $observed
        guard = "args.length != $observed"
    }
}

function Assert-ThreadsModDexBridgeInspectorArgumentContract {
    param(
        [Parameter(Mandatory)][string]$InspectorSourcePath,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedArgumentCount
    )

    $fullPath = [IO.Path]::GetFullPath($InspectorSourcePath)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "DEX bridge inspector source is missing: $fullPath"
    }
    $text = [IO.File]::ReadAllText($fullPath, [Text.Encoding]::UTF8)
    return Assert-ThreadsModDexBridgeInspectorArgumentTextContract `
        -Text $text -ReviewedArgumentCount $ReviewedArgumentCount `
        -Label 'DEX bridge inspector source'
}

function Get-ThreadsModExactArrayAssignment {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][string]$Label,
        [switch]$InvocationWrapper
    )

    $writes = @($Ast.FindAll({
                param($node)
                if ($node -isnot [Management.Automation.Language.AssignmentStatementAst]) {
                    return $false
                }
                return @($node.Left.FindAll({
                            param($leftNode)
                            $leftNode -is [Management.Automation.Language.VariableExpressionAst] `
                                -and -not $leftNode.Splatted `
                                -and $leftNode.VariablePath.UserPath.Equals(
                                    $VariableName, [StringComparison]::Ordinal)
                        }, $true)).Count -gt 0
            }, $true))
    if ($writes.Count -ne 1 `
            -or $writes[0].Left -isnot [Management.Automation.Language.VariableExpressionAst] `
            -or $writes[0].Left.VariablePath.UserPath `
                -cne $VariableName) {
        throw "$Label must assign '$VariableName' exactly once without later mutation."
    }
    $command = $null
    if ($writes[0].Right -isnot [Management.Automation.Language.CommandExpressionAst] `
            -or $writes[0].Right.Expression `
                -isnot [Management.Automation.Language.ArrayExpressionAst]) {
        throw "$Label must use one exact array-expression assignment."
    }
    $arrayExpression = $writes[0].Right.Expression
    $statements = @($arrayExpression.SubExpression.Statements)
    if ($statements.Count -ne 1) {
        throw "$Label must contain one executable array-expression statement."
    }
    $pipelineElements = @($statements[0].PipelineElements)
    if ($pipelineElements.Count -ne 1) {
        throw "$Label array expression has an unreviewed pipeline."
    }
    if ($InvocationWrapper) {
        if ($pipelineElements[0] -isnot [Management.Automation.Language.CommandAst]) {
            throw "$Label must execute one direct invocation."
        }
        $command = $pipelineElements[0]
        $arrays = @($command.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.ArrayLiteralAst]
                }, $true))
    } else {
        if ($pipelineElements[0] `
                -isnot [Management.Automation.Language.CommandExpressionAst] `
                -or $pipelineElements[0].Expression `
                    -isnot [Management.Automation.Language.ArrayLiteralAst]) {
            throw "$Label must execute one direct flat array literal."
        }
        $arrays = @($pipelineElements[0].Expression)
    }
    if ($arrays.Count -ne 1) {
        throw "$Label must contain one live flat array literal."
    }
    return [pscustomobject]@{
        assignment = $writes[0]
        array = $arrays[0]
        command = $command
    }
}

function ConvertTo-ThreadsModBridgeSemanticBinding {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.Ast]$Expression,
        [Parameter(Mandatory)][ValidateSet(
            'Wrapper', 'CurrentFixture', 'LegacyFixture')][string]$Context,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Expression -isnot [Management.Automation.Language.ConvertExpressionAst] `
            -or -not ([string]$Expression.Type.TypeName).Equals(
                'string', [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must be one explicit string-cast semantic binding."
    }
    $current = $Expression.Child
    $members = [Collections.Generic.List[string]]::new()
    while ($current -is [Management.Automation.Language.MemberExpressionAst]) {
        if ($current.Static `
                -or $current.Member -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
            throw "$Label contains a dynamic semantic member."
        }
        $members.Insert(0, [string]$current.Member.Value)
        $current = $current.Expression
    }
    if ($current -isnot [Management.Automation.Language.VariableExpressionAst] `
            -or $current.Splatted) {
        throw "$Label does not originate at one reviewed variable."
    }
    $variable = [string]$current.VariablePath.UserPath
    if ((($Context -ceq 'Wrapper' -and $variable -ceq 'contract') `
                -or ($Context -in @('CurrentFixture', 'LegacyFixture') `
                    -and $variable -ceq 'bridgeFlowContract')) `
            -and $members.Count -eq 1) {
        return 'contract.' + $members[0]
    }
    if ($Context -ceq 'Wrapper' `
            -and $variable.Equals('symbols', [StringComparison]::Ordinal) `
            -and $members.Count -eq 1) {
        return 'resolution.bridge.symbols.' + $members[0]
    }
    if ($Context -ceq 'Wrapper' `
            -and $variable.Equals('inlineSymbols', [StringComparison]::Ordinal) `
            -and $members.Count -eq 1) {
        return 'resolution.inlineControls.symbols.' + $members[0]
    }
    if ($Context -ceq 'CurrentFixture' `
            -and $variable.Equals('resolution', [StringComparison]::Ordinal) `
            -and $members.Count -eq 3 `
            -and $members[0].Equals('bridge', [StringComparison]::Ordinal) `
            -and $members[1].Equals('symbols', [StringComparison]::Ordinal)) {
        return 'resolution.bridge.symbols.' + $members[2]
    }
    if ($Context -ceq 'CurrentFixture' `
            -and $variable.Equals('resolution', [StringComparison]::Ordinal) `
            -and $members.Count -eq 3 `
            -and $members[0].Equals('inlineControls', [StringComparison]::Ordinal) `
            -and $members[1].Equals('symbols', [StringComparison]::Ordinal)) {
        return 'resolution.inlineControls.symbols.' + $members[2]
    }
    throw "$Label contains an unreviewed semantic binding."
}

function Test-ThreadsModExactVariableExpression {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.Ast]$Expression,
        [Parameter(Mandatory)][string]$VariableName
    )

    return $Expression -is [Management.Automation.Language.VariableExpressionAst] `
        -and -not $Expression.Splatted `
        -and $Expression.VariablePath.UserPath.Equals(
            $VariableName, [StringComparison]::Ordinal)
}

function Assert-ThreadsModArgumentArrayReferenceClosure {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][Management.Automation.Language.VariableExpressionAst]$Declaration,
        [Parameter(Mandatory)][ValidateRange(1, 10)][int]$ExpectedJoinReferences,
        [switch]$RequireCountGuard
    )

    $references = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.VariableExpressionAst] `
                    -and -not $node.Splatted `
                    -and $node.VariablePath.UserPath.Equals(
                        $VariableName, [StringComparison]::Ordinal)
            }, $true))
    $allowed = [Collections.Generic.HashSet[int]]::new()
    $null = $allowed.Add([int]$Declaration.Extent.StartOffset)
    $joinReferences = @($references | Where-Object {
            $_.Parent -is [Management.Automation.Language.BinaryExpressionAst] `
                -and $_.Parent.Operator `
                    -eq [Management.Automation.Language.TokenKind]::Plus `
                -and $_.Parent.Right.Extent.StartOffset -eq $_.Extent.StartOffset `
                -and (Get-ThreadsModClosestAncestor `
                    -Node $_ -Type ([Management.Automation.Language.CommandAst])).GetCommandName() `
                    -ceq 'Invoke-ProbeNative'
        })
    if ($joinReferences.Count -ne $ExpectedJoinReferences) {
        throw "Bridge fixture '$VariableName' is not used by the exact reviewed probe count."
    }
    foreach ($reference in $joinReferences) {
        $null = $allowed.Add([int]$reference.Extent.StartOffset)
    }
    if ($RequireCountGuard) {
        $countReferences = @($references | Where-Object {
                $_.Parent -is [Management.Automation.Language.MemberExpressionAst] `
                    -and $_.Parent.Member `
                        -is [Management.Automation.Language.StringConstantExpressionAst] `
                    -and [string]$_.Parent.Member.Value -ceq 'Count'
            })
        if ($countReferences.Count -ne 1) {
            throw "Bridge fixture '$VariableName' must have one exact count guard."
        }
        $comparison = $countReferences[0].Parent.Parent
        $guard = Get-ThreadsModClosestAncestor `
            -Node $comparison -Type ([Management.Automation.Language.IfStatementAst])
        if ($comparison -isnot [Management.Automation.Language.BinaryExpressionAst] `
                -or $comparison.Operator -ne [Management.Automation.Language.TokenKind]::Ine `
                -or $comparison.Left.Extent.StartOffset `
                    -ne $countReferences[0].Parent.Extent.StartOffset `
                -or $comparison.Right `
                    -isnot [Management.Automation.Language.ConstantExpressionAst] `
                -or $comparison.Right.StaticType -ne [int32] `
                -or [int]$comparison.Right.Value -ne 27 `
                -or $comparison.Right.Extent.Text -cne '27' `
                -or $null -eq $guard `
                -or -not (Test-ThreadsModExactFailClosedEvidenceGuard `
                    -Node $comparison -Guard $guard) `
                -or $guard.Parent `
                    -isnot [Management.Automation.Language.NamedBlockAst] `
                -or $guard.Parent.Extent.StartOffset -ne $Ast.EndBlock.Extent.StartOffset) {
            throw "Bridge fixture '$VariableName' count guard is not the exact live fail-closed guard."
        }
        $null = $allowed.Add([int]$countReferences[0].Extent.StartOffset)
    }
    if ($references.Count -ne $allowed.Count `
            -or @($references | Where-Object {
                    -not $allowed.Contains([int]$_.Extent.StartOffset)
                }).Count -ne 0) {
        throw "Bridge fixture '$VariableName' has an unreviewed read or mutation."
    }
}

function Assert-ThreadsModAliasMutationClosure {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)][string]$VariableName,
        [Parameter(Mandatory)][Management.Automation.Language.AssignmentStatementAst]$Declaration
    )

    $writes = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] `
                    -and @($node.Left.FindAll({
                                param($leftNode)
                                $leftNode -is [Management.Automation.Language.VariableExpressionAst] `
                                    -and $leftNode.VariablePath.UserPath.Equals(
                                        $VariableName, [StringComparison]::Ordinal)
                            }, $true)).Count -gt 0
            }, $true))
    if ($writes.Count -ne 1 `
            -or $writes[0].Extent.StartOffset -ne $Declaration.Extent.StartOffset) {
        throw "Patched-APK '$VariableName' alias has an unreviewed assignment."
    }
    $mutatingInvocations = @($Ast.FindAll({
                param($node)
                if ($node -isnot [Management.Automation.Language.InvokeMemberExpressionAst]) {
                    return $false
                }
                return @($node.Expression.FindAll({
                            param($expressionNode)
                            $expressionNode `
                                -is [Management.Automation.Language.VariableExpressionAst] `
                                -and $expressionNode.VariablePath.UserPath.Equals(
                                    $VariableName, [StringComparison]::Ordinal)
                        }, $true)).Count -gt 0
            }, $true))
    if ($mutatingInvocations.Count -ne 0) {
        throw "Patched-APK '$VariableName' alias may not be invoked or mutated."
    }
}

function Assert-ThreadsModNoIndirectVariableMutation {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)][string]$Label
    )

    $forbidden = @(
        'Set-Variable', 'New-Variable', 'Remove-Variable', 'Clear-Variable',
        'Get-Variable', 'Set-Item', 'New-Item', 'Remove-Item', 'Clear-Item',
        'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty',
        'Invoke-Expression', 'iex')
    $commands = @($Ast.FindAll({
                param($node)
                if ($node -isnot [Management.Automation.Language.CommandAst]) {
                    return $false
                }
                $name = $node.GetCommandName()
                return -not [string]::IsNullOrWhiteSpace($name) `
                    -and $name -iin $forbidden
            }, $true))
    if ($commands.Count -ne 0) {
        throw "$Label contains an indirect variable-provider or expression mutation command."
    }
}

function Get-ThreadsModBridgeProbeLanes {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast
    )

    $commands = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CommandAst] `
                    -and $node.GetCommandName() -ceq 'Invoke-ProbeNative'
            }, $true))
    if ($commands.Count -ne 4) {
        throw 'Bridge fixture harness must contain exactly four Invoke-ProbeNative inspector lanes.'
    }
    $lanes = @{}
    foreach ($command in $commands) {
        $elements = @($command.CommandElements)
        if ($elements.Count -ne 5 `
                -or $elements[1] -isnot [Management.Automation.Language.CommandParameterAst] `
                -or $elements[1].ParameterName -cne 'Command' `
                -or -not (Test-ThreadsModExactVariableExpression `
                    -Expression $elements[2] -VariableName 'Java') `
                -or $elements[3] -isnot [Management.Automation.Language.CommandParameterAst] `
                -or $elements[3].ParameterName -cne 'Arguments' `
                -or $elements[4] -isnot [Management.Automation.Language.ParenExpressionAst]) {
            throw 'Bridge fixture probe must use the exact Java and parenthesized Arguments shape.'
        }
        $pipelineElements = @($elements[4].Pipeline.PipelineElements)
        if ($pipelineElements.Count -ne 1 `
                -or $pipelineElements[0] `
                    -isnot [Management.Automation.Language.CommandExpressionAst] `
                -or $pipelineElements[0].Expression `
                    -isnot [Management.Automation.Language.BinaryExpressionAst]) {
            throw 'Bridge fixture probe must concatenate one fixed prefix and one argument array.'
        }
        $join = $pipelineElements[0].Expression
        if ($join.Operator -ne [Management.Automation.Language.TokenKind]::Plus `
                -or $join.Left -isnot [Management.Automation.Language.ArrayExpressionAst] `
                -or $join.Right -isnot [Management.Automation.Language.VariableExpressionAst] `
                -or $join.Right.Splatted) {
            throw 'Bridge fixture probe argument concatenation has an unreviewed shape.'
        }
        $prefixArrays = @($join.Left.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.ArrayLiteralAst]
                }, $true))
        if ($prefixArrays.Count -ne 1 -or $prefixArrays[0].Elements.Count -ne 4) {
            throw 'Bridge fixture probe prefix must contain exactly classpath, inspector, and APK.'
        }
        $prefixStatements = @($join.Left.SubExpression.Statements)
        $prefixPipeline = @(if ($prefixStatements.Count -eq 1) {
            $prefixStatements[0].PipelineElements
        })
        if ($prefixPipeline.Count -ne 1 `
                -or $prefixPipeline[0] `
                    -isnot [Management.Automation.Language.CommandExpressionAst] `
                -or $prefixPipeline[0].Expression `
                    -isnot [Management.Automation.Language.ArrayLiteralAst] `
                -or $prefixPipeline[0].Expression.Extent.StartOffset `
                    -ne $prefixArrays[0].Extent.StartOffset `
                -or $prefixPipeline[0].Expression.Extent.EndOffset `
                    -ne $prefixArrays[0].Extent.EndOffset) {
            throw 'Bridge fixture probe prefix array is not the live concatenation operand.'
        }
        $prefix = @($prefixArrays[0].Elements)
        if ($prefix[0] -isnot [Management.Automation.Language.StringConstantExpressionAst] `
                -or [string]$prefix[0].Value -cne '-cp' `
                -or -not (Test-ThreadsModExactVariableExpression `
                    -Expression $prefix[1] -VariableName 'helperClasspath') `
                -or $prefix[2] -isnot [Management.Automation.Language.StringConstantExpressionAst] `
                -or [string]$prefix[2].Value -cne 'DexBridgeFlowInspector') {
            throw 'Bridge fixture probe prefix differs from the reviewed inspector invocation.'
        }
        $assignment = Get-ThreadsModClosestAncestor `
            -Node $command -Type ([Management.Automation.Language.AssignmentStatementAst])
        $loop = Get-ThreadsModClosestAncestor `
            -Node $command -Type ([Management.Automation.Language.ForEachStatementAst])
        if ($null -eq $assignment `
                -or $assignment.Left -isnot [Management.Automation.Language.VariableExpressionAst] `
                -or $assignment.Right `
                    -isnot [Management.Automation.Language.PipelineAst] `
                -or @($assignment.Right.PipelineElements).Count -ne 1 `
                -or $assignment.Right.PipelineElements[0].Extent.StartOffset `
                    -ne $command.Extent.StartOffset `
                -or $assignment.Right.PipelineElements[0].Extent.EndOffset `
                    -ne $command.Extent.EndOffset) {
            throw 'Bridge fixture probe must be captured by one reviewed result variable.'
        }
        $assignmentName = [string]$assignment.Left.VariablePath.UserPath
        $argumentName = [string]$join.Right.VariablePath.UserPath
        $apkName = if ($prefix[3] -is [Management.Automation.Language.VariableExpressionAst]) {
            [string]$prefix[3].VariablePath.UserPath
        } else { '' }
        $lane = $null
        $expectedArguments = $null
        $expectedApk = $null
        if ($null -eq $loop -and $assignmentName -ceq 'positiveProbe') {
            $lane = 'legacy-positive'; $expectedArguments = 'commonArguments'; $expectedApk = 'positiveApk'
        } elseif ($null -eq $loop -and $assignmentName -ceq 'currentPositiveProbe') {
            $lane = 'current-positive'; $expectedArguments = 'currentArguments'; $expectedApk = 'currentPositiveApk'
        } elseif ($null -ne $loop -and $assignmentName -ceq 'probe' `
                -and $loop.Variable.VariablePath.UserPath -ceq 'fixture' `
                -and (Test-ThreadsModExactCollectionPipeline `
                    -Pipeline $loop.Condition -VariableName 'negativeFixtures' `
                    -MemberPath @())) {
            $lane = 'legacy-negative'; $expectedArguments = 'commonArguments'; $expectedApk = 'fixtureApk'
        } elseif ($null -ne $loop -and $assignmentName -ceq 'probe' `
                -and $loop.Variable.VariablePath.UserPath -ceq 'fixture' `
                -and (Test-ThreadsModExactCollectionPipeline `
                    -Pipeline $loop.Condition -VariableName 'singleTargetNegativeFixtures' `
                    -MemberPath @())) {
            $lane = 'current-negative'; $expectedArguments = 'currentArguments'; $expectedApk = 'fixtureApk'
        }
        if ($null -eq $loop) {
            if ($assignment.Parent `
                    -isnot [Management.Automation.Language.NamedBlockAst] `
                    -or $assignment.Parent.Extent.StartOffset `
                        -ne $Ast.EndBlock.Extent.StartOffset) {
                throw 'Positive bridge fixture probe must execute directly in the harness body.'
            }
        } elseif ($assignment.Parent `
                -isnot [Management.Automation.Language.StatementBlockAst] `
                -or $assignment.Parent.Extent.StartOffset -ne $loop.Body.Extent.StartOffset `
                -or $loop.Parent -isnot [Management.Automation.Language.NamedBlockAst] `
                -or $loop.Parent.Extent.StartOffset -ne $Ast.EndBlock.Extent.StartOffset) {
            throw 'Negative bridge fixture probe must execute directly in its reviewed loop body.'
        }
        if ($null -eq $lane `
                -or $argumentName -cne $expectedArguments `
                -or $apkName -cne $expectedApk `
                -or $lanes.ContainsKey($lane)) {
            throw 'Bridge fixture probe is duplicated, misplaced, or uses the wrong lane arguments/APK.'
        }
        $lanes[$lane] = [pscustomobject]@{
            line = [int]$command.Extent.StartLineNumber
            arguments = $argumentName
            apk = $apkName
            assignment = $assignmentName
        }
    }
    $expectedLanes = @(
        'legacy-positive', 'legacy-negative', 'current-positive', 'current-negative')
    if (@($expectedLanes | Where-Object { -not $lanes.ContainsKey($_) }).Count -ne 0) {
        throw 'Bridge fixture harness does not cover every reviewed inspector lane.'
    }
    foreach ($writeContract in @(
            [pscustomobject]@{ variable = 'positiveProbe'; count = 1 },
            [pscustomobject]@{ variable = 'currentPositiveProbe'; count = 1 },
            [pscustomobject]@{ variable = 'probe'; count = 2 })) {
        $writes = @($Ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] `
                        -and @($node.Left.FindAll({
                                    param($leftNode)
                                    $leftNode `
                                        -is [Management.Automation.Language.VariableExpressionAst] `
                                        -and $leftNode.VariablePath.UserPath.Equals(
                                            [string]$writeContract.variable,
                                            [StringComparison]::Ordinal)
                                }, $true)).Count -gt 0
                }, $true))
        if ($writes.Count -ne [int]$writeContract.count) {
            throw "Bridge fixture probe '$($writeContract.variable)' has an unreviewed write."
        }
    }
    return $lanes
}

function Assert-ThreadsModBridgePositiveResultBinding {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast
    )

    $cases = @(
        [pscustomobject]@{
            result = 'positiveResult'; probe = 'positiveProbe'; fixture = 'positive'
            assertion = 'Assert-PositiveEvidence'; parameter = 'Result'
            assertionResult = 'positiveResult'
        },
        [pscustomobject]@{
            result = 'currentPositiveResult'; probe = 'currentPositiveProbe'
            fixture = 'positive-single-target'
            assertion = 'Assert-SingleTargetPositiveEvidence'; parameter = 'CurrentResult'
            assertionResult = 'currentPositiveResult'
        }
    )
    $proofs = @()
    foreach ($case in $cases) {
        $assignments = @($Ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] `
                        -and @($node.Left.FindAll({
                                    param($leftNode)
                                    $leftNode `
                                        -is [Management.Automation.Language.VariableExpressionAst] `
                                        -and $leftNode.VariablePath.UserPath.Equals(
                                            [string]$case.result,
                                            [StringComparison]::Ordinal)
                                }, $true)).Count -gt 0
                }, $true))
        if ($assignments.Count -ne 1 `
                -or $assignments[0].Left `
                    -isnot [Management.Automation.Language.VariableExpressionAst] `
                -or $assignments[0].Right `
                    -isnot [Management.Automation.Language.PipelineAst] `
                -or $assignments[0].Parent `
                    -isnot [Management.Automation.Language.NamedBlockAst] `
                -or $assignments[0].Parent.Extent.StartOffset `
                    -ne $Ast.EndBlock.Extent.StartOffset) {
            throw "Bridge fixture must bind '$($case.result)' exactly once."
        }
        $parseCommands = @($assignments[0].Right.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] `
                        -and $node.GetCommandName() -ceq 'Get-JsonResult'
                }, $true))
        if ($parseCommands.Count -ne 1) {
            throw "Bridge fixture '$($case.result)' must come from one Get-JsonResult call."
        }
        if (@($assignments[0].Right.PipelineElements).Count -ne 1 `
                -or $assignments[0].Right.PipelineElements[0].Extent.StartOffset `
                    -ne $parseCommands[0].Extent.StartOffset `
                -or $assignments[0].Right.PipelineElements[0].Extent.EndOffset `
                    -ne $parseCommands[0].Extent.EndOffset) {
            throw "Bridge fixture '$($case.result)' parser is not the live assignment RHS."
        }
        $parse = @($parseCommands[0].CommandElements)
        if ($parse.Count -ne 5 `
                -or $parse[1] -isnot [Management.Automation.Language.CommandParameterAst] `
                -or $parse[1].ParameterName -cne 'Lines' `
                -or -not (Test-ThreadsModExactMemberPath `
                    -Expression $parse[2] -VariableName ([string]$case.probe) `
                    -MemberPath @('lines')) `
                -or $parse[3] -isnot [Management.Automation.Language.CommandParameterAst] `
                -or $parse[3].ParameterName -cne 'FixtureId' `
                -or $parse[4] -isnot [Management.Automation.Language.StringConstantExpressionAst] `
                -or [string]$parse[4].Value -cne [string]$case.fixture) {
            throw "Bridge fixture '$($case.result)' is parsed from the wrong probe or identity."
        }
        $assertions = @($Ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] `
                        -and $node.GetCommandName() -ceq [string]$case.assertion
                }, $true))
        if ($assertions.Count -ne 1) {
            throw "Bridge fixture must invoke '$($case.assertion)' exactly once."
        }
        $assertionElements = @($assertions[0].CommandElements)
        if ($assertionElements.Count -lt 3 `
                -or $assertionElements[1] `
                    -isnot [Management.Automation.Language.CommandParameterAst] `
                -or $assertionElements[1].ParameterName -cne [string]$case.parameter `
                -or -not (Test-ThreadsModExactVariableExpression `
                    -Expression $assertionElements[2] `
                    -VariableName ([string]$case.assertionResult)) `
                -or $assertions[0].Extent.StartOffset `
                    -le $assignments[0].Extent.EndOffset `
                -or $assertions[0].Parent `
                    -isnot [Management.Automation.Language.PipelineAst] `
                -or $assertions[0].Parent.Parent `
                    -isnot [Management.Automation.Language.NamedBlockAst] `
                -or $assertions[0].Parent.Parent.Extent.StartOffset `
                    -ne $Ast.EndBlock.Extent.StartOffset) {
            throw "Bridge fixture '$($case.assertion)' is not bound to its reviewed positive result."
        }
        $probeAssignments = @($Ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] `
                        -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] `
                        -and $node.Left.VariablePath.UserPath.Equals(
                            [string]$case.probe, [StringComparison]::Ordinal)
                }, $true))
        if ($probeAssignments.Count -ne 1 `
                -or $probeAssignments[0].Extent.EndOffset `
                    -ge $assignments[0].Extent.StartOffset) {
            throw "Bridge fixture '$($case.result)' is not ordered after its unique live probe."
        }
        if ([string]$case.assertion -ceq 'Assert-PositiveEvidence') {
            if ($assertionElements.Count -ne 3) {
                throw 'Legacy positive bridge assertion has extra authority arguments.'
            }
        } else {
            if ($assertionElements.Count -ne 7 `
                    -or $assertionElements[3] `
                        -isnot [Management.Automation.Language.CommandParameterAst] `
                    -or $assertionElements[3].ParameterName -cne 'Contract' `
                    -or -not (Test-ThreadsModExactVariableExpression `
                        -Expression $assertionElements[4] -VariableName 'bridgeFlowContract') `
                    -or $assertionElements[5] `
                        -isnot [Management.Automation.Language.CommandParameterAst] `
                    -or $assertionElements[5].ParameterName -cne 'Symbols' `
                    -or -not (Test-ThreadsModExactMemberPath `
                        -Expression $assertionElements[6] -VariableName 'resolution' `
                        -MemberPath @('bridge', 'symbols'))) {
                throw 'Current positive bridge assertion is missing its exact contract/symbol binding.'
            }
        }
        $proofs += [pscustomobject]@{
            result = [string]$case.result
            probe = [string]$case.probe
            assertion = [string]$case.assertion
        }
    }
    return $proofs
}

function Assert-ThreadsModDexBridgeInspectorBindingContract {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$ReleaseWrapperAst,
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$FixtureHarnessAst,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedArgumentCount
    )

    $expected = @(
        'contract.ownerClassDescriptor',
        'contract.blockMethodName',
        'contract.blockResolvedMethodName',
        'contract.blockModelMethodName',
        'contract.prepareModelMethodName',
        'resolution.bridge.symbols.sessionDescriptor',
        'resolution.bridge.symbols.modelDescriptor',
        'resolution.bridge.symbols.cacheLookupMethod',
        'resolution.bridge.symbols.userCacheFactoryMethod',
        'resolution.bridge.symbols.userCacheGetOrPutMethod',
        'resolution.bridge.symbols.authorIdMethod',
        'resolution.bridge.symbols.alreadyBlockedMethod',
        'resolution.bridge.symbols.blockMutationMethod',
        'resolution.bridge.symbols.surface',
        'resolution.bridge.symbols.mutationStartedCallback',
        'resolution.bridge.symbols.mutationFailureCallback',
        'resolution.bridge.symbols.mutationEndedCallback',
        'resolution.bridge.symbols.mutationCancelCallback',
        'resolution.bridge.symbols.mutationSuccessCallback',
        'resolution.bridge.symbols.mutationCallbackInterface',
        'contract.automaticCallerClassDescriptor',
        'contract.manualCallerClassDescriptor',
        'contract.fetchWorkerRunMethodReference',
        'contract.scheduleManualDrainMethodReference',
        'resolution.inlineControls.symbols.mediaLookupMethod',
        'resolution.inlineControls.symbols.mediaAuthorMethod',
        'resolution.inlineControls.symbols.authorUsernameMethod'
    )
    if ($expected.Count -ne 27 `
            -or $ReviewedArgumentCount -ne (1 + $expected.Count)) {
        throw 'Reviewed bridge inspector argument count must cover APK plus 27 semantic bindings.'
    }
    Assert-ThreadsModNoIndirectVariableMutation `
        -Ast $ReleaseWrapperAst -Label 'Patched-APK bridge inspector wrapper'
    Assert-ThreadsModNoIndirectVariableMutation `
        -Ast $FixtureHarnessAst -Label 'Bridge inspector fixture harness'

    $wrapperArray = Get-ThreadsModExactArrayAssignment `
        -Ast $ReleaseWrapperAst -VariableName 'bridgeLines' `
        -Label 'Patched-APK bridge inspector invocation' -InvocationWrapper
    $wrapperElements = @($wrapperArray.array.Elements)
    $wrapperCommandElements = @($wrapperArray.command.CommandElements)
    $wrapperArgumentStatements = @(if ($wrapperCommandElements.Count -eq 5 `
            -and $wrapperCommandElements[4] `
                -is [Management.Automation.Language.ArrayExpressionAst]) {
        $wrapperCommandElements[4].SubExpression.Statements
    })
    $wrapperArgumentPipeline = @(if ($wrapperArgumentStatements.Count -eq 1) {
        $wrapperArgumentStatements[0].PipelineElements
    })
    if ($wrapperArray.command.GetCommandName() -cne 'Invoke-Captured' `
            -or $wrapperCommandElements.Count -ne 5 `
            -or $wrapperCommandElements[1] `
                -isnot [Management.Automation.Language.CommandParameterAst] `
            -or $wrapperCommandElements[1].ParameterName -cne 'Command' `
            -or -not (Test-ThreadsModExactVariableExpression `
                -Expression $wrapperCommandElements[2] -VariableName 'Java') `
            -or $wrapperCommandElements[3] `
                -isnot [Management.Automation.Language.CommandParameterAst] `
            -or $wrapperCommandElements[3].ParameterName -cne 'Arguments' `
            -or $wrapperCommandElements[4] `
                -isnot [Management.Automation.Language.ArrayExpressionAst] `
            -or $wrapperArgumentPipeline.Count -ne 1 `
            -or $wrapperArgumentPipeline[0] `
                -isnot [Management.Automation.Language.CommandExpressionAst] `
            -or $wrapperArgumentPipeline[0].Expression `
                -isnot [Management.Automation.Language.ArrayLiteralAst] `
            -or $wrapperArgumentPipeline[0].Expression.Extent.StartOffset `
                -ne $wrapperArray.array.Extent.StartOffset `
            -or $wrapperArgumentPipeline[0].Expression.Extent.EndOffset `
                -ne $wrapperArray.array.Extent.EndOffset `
            -or $wrapperElements.Count -ne 31 `
            -or $wrapperElements[0] `
                -isnot [Management.Automation.Language.StringConstantExpressionAst] `
            -or [string]$wrapperElements[0].Value -cne '-cp' `
            -or -not (Test-ThreadsModExactVariableExpression `
                -Expression $wrapperElements[1] -VariableName 'dexLiteralClasspath') `
            -or $wrapperElements[2] `
                -isnot [Management.Automation.Language.StringConstantExpressionAst] `
            -or [string]$wrapperElements[2].Value -cne 'DexBridgeFlowInspector' `
            -or -not (Test-ThreadsModExactVariableExpression `
                -Expression $wrapperElements[3] -VariableName 'apkFull')) {
        throw 'Patched-APK bridge inspector invocation prefix or arity drifted.'
    }
    $wrapperLoop = Get-ThreadsModBridgeWrapperEvidenceLane -Ast $ReleaseWrapperAst
    if ($wrapperArray.assignment.Parent -isnot [Management.Automation.Language.StatementBlockAst] `
            -or $wrapperArray.assignment.Parent.Extent.StartOffset `
                -ne $wrapperLoop.body.Extent.StartOffset) {
        throw 'Patched-APK bridge inspector invocation escaped the reviewed bridge loop.'
    }
    $bridgeResultWrites = @($ReleaseWrapperAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] `
                    -and @($node.Left.FindAll({
                                param($leftNode)
                                $leftNode `
                                    -is [Management.Automation.Language.VariableExpressionAst] `
                                    -and $leftNode.VariablePath.UserPath.Equals(
                                        'bridgeResult', [StringComparison]::Ordinal)
                            }, $true)).Count -gt 0
            }, $true))
    if ($bridgeResultWrites.Count -ne 1 `
            -or $bridgeResultWrites[0].Left `
                -isnot [Management.Automation.Language.VariableExpressionAst] `
            -or $bridgeResultWrites[0].Right `
                -isnot [Management.Automation.Language.PipelineAst]) {
        throw 'Patched-APK bridge result must be assigned exactly once.'
    }
    $bridgeResultPipeline = @($bridgeResultWrites[0].Right.PipelineElements)
    if ($bridgeResultPipeline.Count -ne 2 `
            -or $bridgeResultPipeline[0] `
                -isnot [Management.Automation.Language.CommandExpressionAst] `
            -or $bridgeResultPipeline[0].Expression `
                -isnot [Management.Automation.Language.IndexExpressionAst] `
            -or -not (Test-ThreadsModExactVariableExpression `
                -Expression $bridgeResultPipeline[0].Expression.Target `
                -VariableName 'bridgeLines') `
            -or $bridgeResultPipeline[0].Expression.Index `
                -isnot [Management.Automation.Language.ConstantExpressionAst] `
            -or $bridgeResultPipeline[0].Expression.Index.StaticType -ne [int32] `
            -or [int]$bridgeResultPipeline[0].Expression.Index.Value -ne -1 `
            -or $bridgeResultPipeline[0].Expression.Index.Extent.Text -cne '-1' `
            -or $bridgeResultPipeline[1] `
                -isnot [Management.Automation.Language.CommandAst] `
            -or $bridgeResultPipeline[1].GetCommandName() -cne 'ConvertFrom-Json' `
            -or @($bridgeResultPipeline[1].CommandElements).Count -ne 1 `
            -or $bridgeResultWrites[0].Parent `
                -isnot [Management.Automation.Language.StatementBlockAst] `
            -or $bridgeResultWrites[0].Parent.Extent.StartOffset `
                -ne $wrapperLoop.body.Extent.StartOffset `
            -or $bridgeResultWrites[0].Extent.StartOffset `
                -le $wrapperArray.assignment.Extent.EndOffset `
            -or $bridgeResultWrites[0].Extent.EndOffset `
                -ge $wrapperLoop.version.Extent.StartOffset) {
        throw 'Patched-APK bridge evidence is not parsed exactly once from the live inspector output.'
    }
    $bridgeLineReferences = @($ReleaseWrapperAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.VariableExpressionAst] `
                    -and $node.VariablePath.UserPath.Equals(
                        'bridgeLines', [StringComparison]::Ordinal)
            }, $true))
    if ($bridgeLineReferences.Count -ne 2 `
            -or @($bridgeLineReferences | Where-Object {
                    $_.Extent.StartOffset -ne $wrapperArray.assignment.Left.Extent.StartOffset `
                        -and $_.Extent.StartOffset `
                            -ne $bridgeResultPipeline[0].Expression.Target.Extent.StartOffset
                }).Count -ne 0) {
        throw 'Patched-APK bridgeLines has an unreviewed read or mutation before evidence parsing.'
    }
    $aliasContracts = @(
        [pscustomobject]@{
            variable = 'symbols'; members = @('bridge', 'symbols')
        },
        [pscustomobject]@{
            variable = 'inlineSymbols'; members = @('inlineControls', 'symbols')
        }
    )
    $aliasDeclarations = @{}
    foreach ($aliasContract in $aliasContracts) {
        $aliases = @($ReleaseWrapperAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.AssignmentStatementAst] `
                        -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] `
                        -and $node.Left.VariablePath.UserPath.Equals(
                            [string]$aliasContract.variable, [StringComparison]::Ordinal)
                }, $true))
        if ($aliases.Count -ne 1 `
                -or $aliases[0].Right `
                    -isnot [Management.Automation.Language.CommandExpressionAst] `
                -or -not (Test-ThreadsModExactMemberPath `
                    -Expression $aliases[0].Right.Expression `
                    -VariableName 'resolution' -MemberPath @($aliasContract.members)) `
                -or $aliases[0].Parent -isnot [Management.Automation.Language.StatementBlockAst] `
                -or $aliases[0].Parent.Extent.StartOffset `
                    -ne $wrapperLoop.body.Extent.StartOffset `
                -or $aliases[0].Extent.StartOffset `
                    -ge $wrapperArray.assignment.Extent.StartOffset) {
            throw "Patched-APK '$($aliasContract.variable)' alias is missing, misplaced, or rebound."
        }
        Assert-ThreadsModAliasMutationClosure `
            -Ast $ReleaseWrapperAst `
            -VariableName ([string]$aliasContract.variable) `
            -Declaration $aliases[0]
        $aliasDeclarations[[string]$aliasContract.variable] = $aliases[0]
    }

    $currentArray = Get-ThreadsModExactArrayAssignment `
        -Ast $FixtureHarnessAst -VariableName 'currentArguments' `
        -Label 'Current bridge fixture argument binding'
    $currentElements = @($currentArray.array.Elements)
    if ($currentArray.assignment.Parent `
            -isnot [Management.Automation.Language.NamedBlockAst] `
            -or $currentArray.assignment.Parent.Extent.StartOffset `
                -ne $FixtureHarnessAst.EndBlock.Extent.StartOffset `
            -or $currentElements.Count -ne 27) {
        throw 'Current bridge fixture must bind exactly 27 inspector arguments.'
    }
    $wrapperBindings = @()
    $harnessBindings = @()
    for ($index = 0; $index -lt $expected.Count; $index++) {
        $wrapperBindings += ConvertTo-ThreadsModBridgeSemanticBinding `
            -Expression $wrapperElements[$index + 4] `
            -Context Wrapper `
            -Label "Patched-APK bridge argument $($index + 1)"
        $harnessBindings += ConvertTo-ThreadsModBridgeSemanticBinding `
            -Expression $currentElements[$index] `
            -Context CurrentFixture `
            -Label "Current fixture bridge argument $($index + 1)"
        if ($wrapperBindings[$index] -cne $expected[$index] `
                -or $harnessBindings[$index] -cne $expected[$index]) {
            throw "Bridge inspector semantic binding $($index + 1) differs from the reviewed order."
        }
    }
    foreach ($aliasName in @('symbols', 'inlineSymbols')) {
        $references = @($ReleaseWrapperAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.VariableExpressionAst] `
                        -and $node.VariablePath.UserPath.Equals(
                            $aliasName, [StringComparison]::Ordinal)
                }, $true))
        $allowed = [Collections.Generic.HashSet[int]]::new()
        $null = $allowed.Add(
            [int]$aliasDeclarations[$aliasName].Left.Extent.StartOffset)
        foreach ($element in $wrapperElements[4..30]) {
            foreach ($reference in @($element.FindAll({
                            param($node)
                            $node -is [Management.Automation.Language.VariableExpressionAst] `
                                -and $node.VariablePath.UserPath.Equals(
                                    $aliasName, [StringComparison]::Ordinal)
                        }, $true))) {
                $null = $allowed.Add([int]$reference.Extent.StartOffset)
            }
        }
        if ($aliasName -ceq 'symbols') {
            $external = @($references | Where-Object {
                    -not $allowed.Contains([int]$_.Extent.StartOffset)
                })
            if ($external.Count -ne 1) {
                throw 'Patched-APK symbols alias has an unreviewed read or escape.'
            }
            $member = $external[0].Parent
            if ($member -isnot [Management.Automation.Language.MemberExpressionAst] `
                    -or $member.Member `
                        -isnot [Management.Automation.Language.StringConstantExpressionAst] `
                    -or [string]$member.Member.Value -cne 'mutationCallbackInterface' `
                    -or $member.Parent `
                        -isnot [Management.Automation.Language.ConvertExpressionAst] `
                    -or [string]$member.Parent.Type.TypeName -cne 'string' `
                    -or $member.Parent.Parent `
                        -isnot [Management.Automation.Language.BinaryExpressionAst]) {
                throw 'Patched-APK symbols alias external read is not the exact callback-interface comparison.'
            }
            $callbackComparison = $member.Parent.Parent
            $callbackGuard = Get-ThreadsModClosestAncestor `
                -Node $callbackComparison `
                -Type ([Management.Automation.Language.IfStatementAst])
            if ($null -eq $callbackGuard `
                    -or $callbackGuard.Parent `
                        -isnot [Management.Automation.Language.StatementBlockAst] `
                    -or $callbackGuard.Parent.Extent.StartOffset `
                        -ne $wrapperLoop.body.Extent.StartOffset `
                    -or -not (Test-ThreadsModExactFailClosedEvidenceGuard `
                        -Node $callbackComparison -Guard $callbackGuard)) {
                throw 'Patched-APK symbols callback-interface read escaped common fail-closed evidence.'
            }
            $null = $allowed.Add([int]$external[0].Extent.StartOffset)
        }
        if ($references.Count -ne $allowed.Count `
                -or @($references | Where-Object {
                        -not $allowed.Contains([int]$_.Extent.StartOffset)
                    }).Count -ne 0) {
            throw "Patched-APK '$aliasName' alias has an unreviewed reference."
        }
    }

    $commonArray = Get-ThreadsModExactArrayAssignment `
        -Ast $FixtureHarnessAst -VariableName 'commonArguments' `
        -Label 'Legacy bridge fixture argument binding'
    $commonElements = @($commonArray.array.Elements)
    $legacyLiterals = @(
        'Lthreadsmod/autoblock/ThreadsBlockBridge;',
        'block', 'blockResolved', 'blockModel', 'prepareModel',
        'Lfixture/Session;', 'Lfixture/Model;',
        'Lfixture/CacheLookup;->find(Lfixture/Session;Ljava/lang/String;)Lfixture/Model;',
        'Lfixture/CacheFactory;->create(Lfixture/Session;)Lfixture/Cache;',
        'Lfixture/Cache;->getOrPut(Lfixture/Seed;Ljava/lang/String;)Lfixture/Model;',
        'Lfixture/Model;->id()Ljava/lang/String;',
        'Lfixture/BlockState;->isBlocked(Lfixture/Model;)Z',
        'Lfixture/MutationApi;->block(Landroid/content/Context;Lfixture/ModelInterface;Lfixture/Session;Lfixture/MutationEvents;Ljava/lang/Integer;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;I)V',
        'fixture_surface', 'started', 'failed', 'ended', 'cancelled', 'succeeded',
        'Lfixture/MutationEvents;', 'Lfixture/AutomaticCaller;', 'Lfixture/ManualCaller;'
    )
    if ($commonArray.assignment.Parent `
            -isnot [Management.Automation.Language.NamedBlockAst] `
            -or $commonArray.assignment.Parent.Extent.StartOffset `
                -ne $FixtureHarnessAst.EndBlock.Extent.StartOffset `
            -or $commonElements.Count -ne 27 `
            -or $legacyLiterals.Count -ne 22) {
        throw 'Legacy bridge fixture argument arity drifted.'
    }
    for ($index = 0; $index -lt 22; $index++) {
        if ($commonElements[$index] `
                -isnot [Management.Automation.Language.StringConstantExpressionAst] `
                -or [string]$commonElements[$index].Value -cne $legacyLiterals[$index]) {
            throw "Legacy bridge fixture literal $($index + 1) drifted."
        }
    }
    foreach ($index in @(22, 23)) {
        $binding = ConvertTo-ThreadsModBridgeSemanticBinding `
            -Expression $commonElements[$index] `
            -Context LegacyFixture `
            -Label "Legacy fixture bridge argument $($index + 1)"
        if ($binding -cne $expected[$index]) {
            throw "Legacy bridge fixture semantic argument $($index + 1) drifted."
        }
    }
    $legacyTail = @(
        'Lfixture/MediaLookup;->find(Lfixture/Session;Ljava/lang/String;)Lfixture/Media;',
        'Lfixture/MediaAuthor;->author(Lfixture/Media;)Lfixture/Model;',
        'Lfixture/Username;->name(Lfixture/Model;)Ljava/lang/String;')
    for ($index = 0; $index -lt $legacyTail.Count; $index++) {
        $element = $commonElements[$index + 24]
        if ($element -isnot [Management.Automation.Language.StringConstantExpressionAst] `
                -or [string]$element.Value -cne $legacyTail[$index]) {
            throw "Legacy bridge fixture tail literal $($index + 25) drifted."
        }
    }

    $lanes = Get-ThreadsModBridgeProbeLanes -Ast $FixtureHarnessAst
    Assert-ThreadsModArgumentArrayReferenceClosure `
        -Ast $FixtureHarnessAst -VariableName 'commonArguments' `
        -Declaration $commonArray.assignment.Left -ExpectedJoinReferences 2
    Assert-ThreadsModArgumentArrayReferenceClosure `
        -Ast $FixtureHarnessAst -VariableName 'currentArguments' `
        -Declaration $currentArray.assignment.Left -ExpectedJoinReferences 2 `
        -RequireCountGuard
    $positiveBindings = Assert-ThreadsModBridgePositiveResultBinding `
        -Ast $FixtureHarnessAst
    return [pscustomobject]@{
        status = 'passed'
        argumentCount = $ReviewedArgumentCount
        semanticBindingCount = $expected.Count
        bindings = $expected
        lanes = $lanes
        positiveResults = $positiveBindings
    }
}

function Assert-ThreadsModReportPermalinkInspectorArgumentContract {
    param(
        [Parameter(Mandatory)][string]$InspectorSourcePath,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedArgumentCount
    )

    $fullPath = [IO.Path]::GetFullPath($InspectorSourcePath)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "DEX report-permalink inspector source is missing: $fullPath"
    }
    $text = [IO.File]::ReadAllText($fullPath, [Text.Encoding]::UTF8)
    return Assert-ThreadsModDexBridgeInspectorArgumentTextContract `
        -Text $text -ReviewedArgumentCount $ReviewedArgumentCount `
        -Label 'DEX report-permalink inspector source'
}

function Assert-ThreadsModProxyBootstrapInspectorArgumentContract {
    param(
        [Parameter(Mandatory)][string]$InspectorSourcePath,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedArgumentCount
    )

    $fullPath = [IO.Path]::GetFullPath($InspectorSourcePath)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "DEX proxy-bootstrap inspector source is missing: $fullPath"
    }
    $text = [IO.File]::ReadAllText($fullPath, [Text.Encoding]::UTF8)
    return Assert-ThreadsModDexBridgeInspectorArgumentTextContract `
        -Text $text -ReviewedArgumentCount $ReviewedArgumentCount `
        -Label 'DEX proxy-bootstrap inspector source'
}

function Get-ThreadsModReportPermalinkBindingSequence {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)][string]$AssignmentVariable,
        [Parameter(Mandatory)][string]$ContractVariable,
        [Parameter(Mandatory)][string]$ResolutionVariable,
        [Parameter(Mandatory)][string]$Label
    )

    $assignments = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] `
                    -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] `
                    -and -not $node.Left.Splatted `
                    -and $node.Left.VariablePath.UserPath.Equals(
                        $AssignmentVariable, [StringComparison]::Ordinal)
            }, $true))
    if ($assignments.Count -ne 1) {
        throw "$Label must contain exactly one '$AssignmentVariable' assignment."
    }
    $arrays = @($assignments[0].Right.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ArrayLiteralAst]
            }, $true))
    if ($arrays.Count -ne 1) {
        throw "$Label must contain exactly one flat inspector argument array."
    }
    $elements = @($arrays[0].Elements)
    if ($AssignmentVariable.Equals('reportPermalinkLines', [StringComparison]::Ordinal)) {
        if ($elements.Count -ne 36 `
                -or $elements[0] -isnot [Management.Automation.Language.StringConstantExpressionAst] `
                -or -not ([string]$elements[0].Value).Equals(
                    '-cp', [StringComparison]::Ordinal) `
                -or $elements[1] -isnot [Management.Automation.Language.VariableExpressionAst] `
                -or $elements[1].Splatted `
                -or -not $elements[1].VariablePath.UserPath.Equals(
                    'dexLiteralClasspath', [StringComparison]::Ordinal) `
                -or $elements[2] -isnot [Management.Automation.Language.StringConstantExpressionAst] `
                -or -not ([string]$elements[2].Value).Equals(
                    'DexReportPermalinkFlowInspector', [StringComparison]::Ordinal) `
                -or $elements[3] -isnot [Management.Automation.Language.VariableExpressionAst] `
                -or $elements[3].Splatted `
                -or -not $elements[3].VariablePath.UserPath.Equals(
                    'apkFull', [StringComparison]::Ordinal)) {
            throw "$Label must invoke the inspector with the exact classpath, class, and APK prefix."
        }
        $bindingElements = @($elements[4..35])
    } elseif ($AssignmentVariable.Equals('commonArguments', [StringComparison]::Ordinal)) {
        if ($elements.Count -ne 32) {
            throw "$Label must contain exactly 32 semantic inspector bindings."
        }
        $bindingElements = $elements
    } else {
        throw "$Label uses an unreviewed report-permalink argument assignment."
    }
    $allStringCasts = @($assignments[0].Right.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ConvertExpressionAst] `
                    -and ([string]$node.Type.TypeName).Equals(
                        'string', [StringComparison]::OrdinalIgnoreCase)
            }, $true))
    if ($allStringCasts.Count -ne $bindingElements.Count) {
        throw "$Label contains a report-permalink binding outside the flat inspector argument array."
    }
    $result = [Collections.Generic.List[string]]::new()
    foreach ($cast in $bindingElements) {
        if ($cast -isnot [Management.Automation.Language.ConvertExpressionAst] `
                -or -not ([string]$cast.Type.TypeName).Equals(
                    'string', [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label contains a non-string report-permalink inspector binding."
        }
        $current = $cast.Child
        $members = [Collections.Generic.List[string]]::new()
        while ($current -is [Management.Automation.Language.MemberExpressionAst]) {
            if ($current.Static `
                    -or $current.Member -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
                throw "$Label contains a dynamic report-permalink inspector binding."
            }
            $members.Insert(0, [string]$current.Member.Value)
            $current = $current.Expression
        }
        if ($current -isnot [Management.Automation.Language.VariableExpressionAst] `
                -or $current.Splatted) {
            throw "$Label contains a non-member report-permalink inspector binding."
        }
        $variable = [string]$current.VariablePath.UserPath
        if ($variable.Equals($ContractVariable, [StringComparison]::Ordinal) `
                -and $members.Count -eq 1) {
            $result.Add('contract.' + $members[0])
        } elseif ($variable.Equals($ResolutionVariable, [StringComparison]::Ordinal) `
                -and $members.Count -eq 3 `
                -and $members[0].Equals('reporting', [StringComparison]::Ordinal) `
                -and $members[1].Equals('symbols', [StringComparison]::Ordinal)) {
            $result.Add('resolution.reporting.symbols.' + $members[2])
        } elseif ($variable.Equals($ResolutionVariable, [StringComparison]::Ordinal) `
                -and $members.Count -eq 3 `
                -and $members[0].Equals('inlineControls', [StringComparison]::Ordinal) `
                -and $members[1].Equals('symbols', [StringComparison]::Ordinal)) {
            $result.Add('resolution.inlineControls.symbols.' + $members[2])
        } else {
            throw "$Label contains an unreviewed report-permalink inspector binding."
        }
    }
    return @($result)
}

function Assert-ThreadsModReportPermalinkInspectorBindingContract {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$ReleaseWrapperAst,
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$FixtureHarnessAst,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedArgumentCount
    )

    $expected = @(
        'contract.factoryMethodReference',
        'contract.resolvedMediaGetterReference',
        'resolution.reporting.symbols.mediaBackingField',
        'resolution.reporting.symbols.mediaPermalinkMethod',
        'resolution.reporting.symbols.mediaCaptionMethod',
        'contract.requestConstructorReference',
        'contract.permalinkSanitizerMethodReference',
        'contract.requestPermalinkFieldReference',
        'contract.requestNewQueueValidityMethodReference',
        'contract.requestBaseValidityMethodReference',
        'contract.requestPermalinkGetterReference',
        'contract.payloadToJsonMethodReference',
        'contract.payloadRequestFieldReference',
        'contract.jsonPutMethodReference',
        'contract.jsonArrayPutMethodReference',
        'contract.stringLengthMethodReference',
        'contract.controllerQueueMethodReference',
        'contract.clientQueueMethodReference',
        'contract.threadStartMethodReference',
        'contract.jsonArrayConstructorMethodReference',
        'resolution.reporting.symbols.mediaCodeMethod',
        'resolution.reporting.symbols.captionTextMethod',
        'contract.permalinkResolverMethodReference',
        'contract.excerptResolverMethodReference',
        'contract.rowLabelGetterReference',
        'contract.inlineRowRenderMethodReference',
        'contract.currentViewerMethodReference',
        'resolution.inlineControls.symbols.ufiButtonMethod',
        'resolution.inlineControls.symbols.visibilityModifierMethod',
        'resolution.inlineControls.symbols.testTagMethod',
        'resolution.inlineControls.symbols.modifierComposedMethod',
        'contract.ufiButtonDefaultMask'
    )
    if ($ReviewedArgumentCount -ne (1 + $expected.Count)) {
        throw 'Reviewed report-permalink argument count does not cover APK plus every semantic binding.'
    }
    $wrapper = @(Get-ThreadsModReportPermalinkBindingSequence `
        -Ast $ReleaseWrapperAst -AssignmentVariable 'reportPermalinkLines' `
        -ContractVariable 'reportPermalinkContract' -ResolutionVariable 'resolution' `
        -Label 'Patched-APK report-permalink inspector invocation')
    $harness = @(Get-ThreadsModReportPermalinkBindingSequence `
        -Ast $FixtureHarnessAst -AssignmentVariable 'commonArguments' `
        -ContractVariable 'contract' -ResolutionVariable 'resolution' `
        -Label 'Report-permalink fixture inspector invocation')
    foreach ($observed in @($wrapper, $harness)) {
        if ($observed.Count -ne $expected.Count) {
            throw 'Report-permalink inspector binding count differs from the reviewed contract.'
        }
        for ($index = 0; $index -lt $expected.Count; $index++) {
            if (-not $observed[$index].Equals(
                    $expected[$index], [StringComparison]::Ordinal)) {
                throw 'Report-permalink inspector binding order differs from the reviewed contract.'
            }
        }
    }
    return [pscustomobject]@{
        status = 'passed'
        argumentCount = $ReviewedArgumentCount
        semanticBindingCount = $expected.Count
        bindings = $expected
    }
}

function Get-ThreadsModProxyBootstrapBindingSequence {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$Ast,
        [Parameter(Mandatory)][string]$AssignmentVariable,
        [Parameter(Mandatory)][string]$ContractVariable,
        [Parameter(Mandatory)][string]$Label
    )

    $assignments = @($Ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] `
                    -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] `
                    -and -not $node.Left.Splatted `
                    -and $node.Left.VariablePath.UserPath.Equals(
                        $AssignmentVariable, [StringComparison]::Ordinal)
            }, $true))
    if ($assignments.Count -ne 1) {
        throw "$Label must contain exactly one '$AssignmentVariable' assignment."
    }
    $arrays = @($assignments[0].Right.FindAll({
                param($node)
                $node -is [Management.Automation.Language.ArrayLiteralAst]
            }, $true))
    if ($arrays.Count -ne 1) {
        throw "$Label must contain exactly one flat inspector argument array."
    }
    $elements = @($arrays[0].Elements)
    if ($AssignmentVariable.Equals('proxyBootstrapLines', [StringComparison]::Ordinal)) {
        if ($elements.Count -ne 14 `
                -or $elements[0] -isnot [Management.Automation.Language.StringConstantExpressionAst] `
                -or -not ([string]$elements[0].Value).Equals(
                    '-cp', [StringComparison]::Ordinal) `
                -or $elements[1] -isnot [Management.Automation.Language.VariableExpressionAst] `
                -or $elements[1].Splatted `
                -or -not $elements[1].VariablePath.UserPath.Equals(
                    'dexLiteralClasspath', [StringComparison]::Ordinal) `
                -or $elements[2] -isnot [Management.Automation.Language.StringConstantExpressionAst] `
                -or -not ([string]$elements[2].Value).Equals(
                    'DexProxyBootstrapFlowInspector', [StringComparison]::Ordinal) `
                -or $elements[3] -isnot [Management.Automation.Language.VariableExpressionAst] `
                -or $elements[3].Splatted `
                -or -not $elements[3].VariablePath.UserPath.Equals(
                    'apkFull', [StringComparison]::Ordinal)) {
            throw "$Label must invoke the inspector with the exact classpath, class, and APK prefix."
        }
        $bindingElements = @($elements[4..13])
    } elseif ($AssignmentVariable.Equals('commonArguments', [StringComparison]::Ordinal)) {
        if ($elements.Count -ne 10) {
            throw "$Label must contain exactly ten semantic inspector bindings."
        }
        $bindingElements = $elements
    } else {
        throw "$Label uses an unreviewed proxy-bootstrap argument assignment."
    }
    $result = [Collections.Generic.List[string]]::new()
    foreach ($cast in $bindingElements) {
        if ($cast -isnot [Management.Automation.Language.ConvertExpressionAst] `
                -or -not ([string]$cast.Type.TypeName).Equals(
                    'string', [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label contains a non-string proxy-bootstrap inspector binding."
        }
        $current = $cast.Child
        $members = [Collections.Generic.List[string]]::new()
        while ($current -is [Management.Automation.Language.MemberExpressionAst]) {
            if ($current.Static `
                    -or $current.Member -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
                throw "$Label contains a dynamic proxy-bootstrap inspector binding."
            }
            $members.Insert(0, [string]$current.Member.Value)
            $current = $current.Expression
        }
        if ($current -isnot [Management.Automation.Language.VariableExpressionAst] `
                -or $current.Splatted `
                -or -not $current.VariablePath.UserPath.Equals(
                    $ContractVariable, [StringComparison]::Ordinal) `
                -or $members.Count -ne 1) {
            throw "$Label contains an unreviewed proxy-bootstrap inspector binding."
        }
        $result.Add('contract.' + $members[0])
    }
    return @($result)
}

function Assert-ThreadsModProxyBootstrapInspectorBindingContract {
    param(
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$ReleaseWrapperAst,
        [Parameter(Mandatory)][Management.Automation.Language.ScriptBlockAst]$FixtureHarnessAst,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedArgumentCount
    )

    $expected = @(
        'contract.expectedDexName',
        'contract.ownerClassDescriptor',
        'contract.ownerMethodName',
        'contract.ownerMethodDescriptor',
        'contract.superClassDescriptor',
        'contract.superMethodName',
        'contract.superMethodDescriptor',
        'contract.bootstrapClassDescriptor',
        'contract.bootstrapMethodName',
        'contract.bootstrapMethodDescriptor'
    )
    if ($ReviewedArgumentCount -ne (1 + $expected.Count)) {
        throw 'Reviewed proxy-bootstrap argument count does not cover APK plus every semantic binding.'
    }
    $wrapper = @(Get-ThreadsModProxyBootstrapBindingSequence `
        -Ast $ReleaseWrapperAst -AssignmentVariable 'proxyBootstrapLines' `
        -ContractVariable 'proxyBootstrapContract' `
        -Label 'Patched-APK proxy-bootstrap inspector invocation')
    $harness = @(Get-ThreadsModProxyBootstrapBindingSequence `
        -Ast $FixtureHarnessAst -AssignmentVariable 'commonArguments' `
        -ContractVariable 'contract' `
        -Label 'Proxy-bootstrap fixture inspector invocation')
    foreach ($observed in @($wrapper, $harness)) {
        if ($observed.Count -ne $expected.Count) {
            throw 'Proxy-bootstrap inspector binding count differs from the reviewed contract.'
        }
        for ($index = 0; $index -lt $expected.Count; $index++) {
            if (-not $observed[$index].Equals(
                    $expected[$index], [StringComparison]::Ordinal)) {
                throw 'Proxy-bootstrap inspector binding order differs from the reviewed contract.'
            }
        }
    }
    return [pscustomobject]@{
        status = 'passed'
        argumentCount = $ReviewedArgumentCount
        semanticBindingCount = $expected.Count
        bindings = $expected
    }
}

function Test-ThreadsModReleaseToolInvocationContracts {
    param([Parameter(Mandatory)][string]$ToolsRoot)

    $root = [IO.Path]::GetFullPath($ToolsRoot)
    $contracts = @(
        [pscustomobject]@{ caller='Invoke-PatchletPipeline.ps1'; callee='Test-SplitSourceSetContract.ps1'; script='Test-SplitSourceSetContract.ps1'; variable=''; sets=@([pscustomobject]@{names=@('ScratchRoot','ReportPath')}) },
        [pscustomobject]@{ caller='Invoke-PatchletPipeline.ps1'; callee='Build-SplitSourceUniversalApk.ps1'; script='Build-SplitSourceUniversalApk.ps1'; variable=''; sets=@([pscustomobject]@{names=@('SourceApkSet','OutputDirectory','ResolutionPath','ReportPath','AndroidSdk','BuildToolsVersion','Java','ApkEditorJar')}) },
        [pscustomobject]@{ caller='Invoke-PatchletPipeline.ps1'; callee='Test-PatchletCatalog.ps1'; script='Test-PatchletCatalog.ps1'; variable=''; sets=@([pscustomobject]@{names=@('ResolutionPath','ReportPath')}) },
        [pscustomobject]@{ caller='Invoke-PatchletPipeline.ps1'; callee='Test-HostPatchletAssets.ps1'; script='Test-HostPatchletAssets.ps1'; variable=''; sets=@([pscustomobject]@{names=@('ScratchRoot','ResolutionPath','ReportPath','Java','Javac')}) },
        [pscustomobject]@{ caller='Invoke-PatchletPipeline.ps1'; callee='Test-Resolution.ps1'; script='Test-Resolution.ps1'; variable=''; sets=@([pscustomobject]@{names=@('SourceApk','DecodedRoot','ResolutionPath','ReportPath')}) },
        [pscustomobject]@{ caller='Invoke-PatchletPipeline.ps1'; callee='Build-PatchedApk.ps1'; script='Build-PatchedApk.ps1'; variable=''; sets=@(
            [pscustomobject]@{names=@('DecodedRoot','OutputDirectory','ArtifactBaseName','ResolutionPath','AndroidSdk','BuildToolsVersion','Java')},
            [pscustomobject]@{names=@('DecodedRoot','OutputDirectory','ArtifactBaseName','ResolutionPath','ValidationMode','AndroidSdk','BuildToolsVersion','Java','KeyStore','KeyAlias','KeyStorePasswordEnvironment','KeyPasswordEnvironment','ExpectedDecodedTreeSha256','ExpectedDecodedFiles','ExpectedDecodedDirectories','ExpectedDecodedEntries')}) },
        [pscustomobject]@{ caller='Invoke-PatchletPipeline.ps1'; callee='Apply-Patchlets.ps1'; script='Apply-Patchlets.ps1'; variable=''; sets=@([pscustomobject]@{names=@('SourceApk','DecodedRoot','ScratchRoot','ResolutionPath','LedgerPath','AndroidSdk','BuildToolsVersion','Java','Javac','Jar')}) },
        [pscustomobject]@{ caller='Invoke-PatchletPipeline.ps1'; callee='Test-PatchletIdempotency.ps1'; script='Test-PatchletIdempotency.ps1'; variable=''; sets=@([pscustomobject]@{names=@('SourceApk','DecodedRoot','ScratchRoot','ResolutionPath','ReportPath','AndroidSdk','BuildToolsVersion','Java','Javac','Jar')}) },
        [pscustomobject]@{ caller='Invoke-PatchletPipeline.ps1'; callee='Test-PatchedApk.ps1'; script='Test-PatchedApk.ps1'; variable=''; sets=@([pscustomobject]@{names=@('Apk','SourceApk','ScratchRoot','ResolutionPath','ValidationMode','ReportPath','AndroidSdk','BuildToolsVersion','Java','Javac')}) },
        [pscustomobject]@{ caller='Invoke-PatchletPipeline.ps1'; callee='Test-ActivityUiEmulator.ps1'; script='Test-ActivityUiEmulator.ps1'; variable=''; sets=@([pscustomobject]@{names=@('Apk','ScratchRoot','DeviceSerial','KeyStore','KeyAlias','ResolutionPath','ValidationMode','KeyStorePasswordEnvironment','KeyPasswordEnvironment','AndroidSdk','BuildToolsVersion','Java','SevenZip','ReportPath')}) },
        [pscustomobject]@{ caller='Apply-Patchlets.ps1'; callee='Build-JavaInjection.ps1'; script='Build-JavaInjection.ps1'; variable=''; sets=@([pscustomobject]@{names=@('DecodedRoot','ScratchRoot','ResolutionPath','AndroidSdk','BuildToolsVersion','Java','Javac','Jar')}) },
        [pscustomobject]@{ caller='Test-PatchletIdempotency.ps1'; callee='Apply-Patchlets.ps1'; script='Apply-Patchlets.ps1'; variable=''; sets=@([pscustomobject]@{names=@('SourceApk','DecodedRoot','ScratchRoot','ResolutionPath','AndroidSdk','BuildToolsVersion','Java','Javac','Jar')}) },
        [pscustomobject]@{ caller='Test-PatchedApk.ps1'; callee='Test-DexBridgeFlowInspector.ps1'; script=''; variable='dexBridgeFlowFixtureTest'; sets=@([pscustomobject]@{names=@('ScratchRoot','ResolutionPath','Java','Javac','AndroidSdk','BuildToolsVersion','SevenZip','ReportPath')}) },
        [pscustomobject]@{ caller='Test-DexBridgeFlowInspector.ps1'; callee='Build-JavaInjection.ps1'; script=''; variable='buildJavaInjection'; sets=@([pscustomobject]@{names=@('DecodedRoot','ScratchRoot','ResolutionPath','AndroidSdk','BuildToolsVersion','Java','Javac','Jar','SevenZip','ApktoolJar','FrameworkDirectory')}) },
        [pscustomobject]@{ caller='Test-PatchedApk.ps1'; callee='Test-DexProxyBootstrapFlowInspector.ps1'; script=''; variable='dexProxyBootstrapFlowFixtureTest'; sets=@([pscustomobject]@{names=@('ScratchRoot','ResolutionPath','Java','Javac','ReportPath')}) },
        [pscustomobject]@{ caller='Test-PatchedApk.ps1'; callee='Test-DexReportPermalinkFlowInspector.ps1'; script=''; variable='dexReportPermalinkFlowFixtureTest'; sets=@([pscustomobject]@{names=@('ScratchRoot','ResolutionPath','Java','Javac','ReportPath')}) },
        [pscustomobject]@{ caller='Test-PatchedApk.ps1'; callee='Test-DexUpdateFlowInspector.ps1'; script=''; variable='dexUpdateFlowFixtureTest'; sets=@([pscustomobject]@{names=@('ScratchRoot','ResolutionPath','AndroidSdk','BuildToolsVersion','Java','Javac','ReportPath')}) },
        [pscustomobject]@{ caller='Test-ReleaseContract.ps1'; callee='Test-DexLiteralCallInspector.ps1'; script='Test-DexLiteralCallInspector.ps1'; variable=''; sets=@([pscustomobject]@{names=@('ScratchRoot','ResolutionPath','ReportPath')}) },
        [pscustomobject]@{ caller='Test-ReleaseContract.ps1'; callee='Test-DexBridgeFlowInspector.ps1'; script='Test-DexBridgeFlowInspector.ps1'; variable=''; sets=@([pscustomobject]@{names=@('ScratchRoot','ResolutionPath','ReportPath')}) },
        [pscustomobject]@{ caller='Test-ReleaseContract.ps1'; callee='Test-DexProxyBootstrapFlowInspector.ps1'; script='Test-DexProxyBootstrapFlowInspector.ps1'; variable=''; sets=@([pscustomobject]@{names=@('ScratchRoot','ResolutionPath','ReportPath')}) },
        [pscustomobject]@{ caller='Test-ReleaseContract.ps1'; callee='Test-DexReportPermalinkFlowInspector.ps1'; script='Test-DexReportPermalinkFlowInspector.ps1'; variable=''; sets=@([pscustomobject]@{names=@('ScratchRoot','ResolutionPath','ReportPath')}) },
        [pscustomobject]@{ caller='Test-ReleaseContract.ps1'; callee='Invoke-PatchletPipeline.ps1'; script='Invoke-PatchletPipeline.ps1'; variable=''; sets=@(
            [pscustomobject]@{names=@('SourceApkSet','RunRoot','KeyStore','KeyAlias','ResolutionPath','ValidationMode','ReviewDeviceSerial','BuildToolsVersion')},
            [pscustomobject]@{names=@('SourceApkSet','RunRoot','KeyStore','KeyAlias','ResolutionPath','ValidationMode','BuildToolsVersion','PublishPath')},
            [pscustomobject]@{names=@('SourceApkSet','RunRoot','KeyStore','KeyAlias','ResolutionPath','ValidationMode','ReviewDeviceSerial','PublishPath')},
            [pscustomobject]@{names=@('SourceApkSet','RunRoot','KeyStore','KeyAlias','ResolutionPath','ReviewDeviceSerial')}) }
    )

    $cache = @{}
    $proofs = @()
    $claimedOffsets = @{}
    foreach ($contract in $contracts) {
        foreach ($name in @([string]$contract.caller, [string]$contract.callee)) {
            if (-not $cache.ContainsKey($name)) {
                $cache[$name] = Get-ThreadsModReleaseToolAst `
                    -Path (Join-Path $root $name) -Label $name
            }
        }
        $proof = Assert-ThreadsModReleaseInvocationContract `
            -CallerAst $cache[[string]$contract.caller] `
            -CalleeAst $cache[[string]$contract.callee] `
            -TargetScriptName ([string]$contract.script) `
            -TargetVariableName ([string]$contract.variable) `
            -ExpectedParameterSets @($contract.sets) `
            -Label "$($contract.caller) -> $($contract.callee)"
        $proofs += $proof
        $callerName = [string]$contract.caller
        if (-not $claimedOffsets.ContainsKey($callerName)) {
            $claimedOffsets[$callerName] = [Collections.Generic.HashSet[int]]::new()
        }
        foreach ($invocation in @($proof.invocations)) {
            if (-not $claimedOffsets[$callerName].Add([int]$invocation.startOffset)) {
                throw "Release invocation at offset $($invocation.startOffset) has multiple contracts."
            }
        }
    }

    $allowedNativeVariables = @{
        'Invoke-PatchletPipeline.ps1' = @('Command', 'aapt2')
        'Test-PatchedApk.ps1' = @('Command')
        'Test-DexBridgeFlowInspector.ps1' = @('Command')
    }
    foreach ($callerName in @($claimedOffsets.Keys)) {
        $allowed = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @($allowedNativeVariables[$callerName])) {
            if (-not [string]::IsNullOrWhiteSpace([string]$name)) {
                $null = $allowed.Add([string]$name)
            }
        }
        $discovered = @($cache[$callerName].FindAll({
                    param($node)
                    if ($node -isnot [Management.Automation.Language.CommandAst] `
                            -or $node.CommandElements.Count -eq 0) {
                        return $false
                    }
                    $target = $node.CommandElements[0]
                    if ($target -is [Management.Automation.Language.VariableExpressionAst]) {
                        return -not $allowed.Contains(
                            [string]$target.VariablePath.UserPath)
                    }
                    return @($target.FindAll({
                                param($child)
                                $child -is [Management.Automation.Language.StringConstantExpressionAst] `
                                    -and ([string]$child.Value).EndsWith(
                                        '.ps1', [StringComparison]::OrdinalIgnoreCase)
                            }, $true)).Count -gt 0
                }, $true))
        if ($discovered.Count -ne $claimedOffsets[$callerName].Count) {
            throw "$callerName contains an unowned release-tool or fixture invocation."
        }
        foreach ($command in $discovered) {
            if (-not $claimedOffsets[$callerName].Contains(
                    [int]$command.Extent.StartOffset)) {
                throw "$callerName contains an unowned release-tool or fixture invocation."
            }
        }
    }
    return [pscustomobject]@{
        status = 'passed'
        callers = $claimedOffsets.Count
        contracts = $proofs.Count
        invocations = @($proofs | ForEach-Object { @($_.invocations) }).Count
        proofs = $proofs
    }
}

function Test-ThreadsModReleaseToolContractNegativeFixtures {
    param(
        [Parameter(Mandatory)][ValidateRange(1, 100000)][int]$ReviewedFixtureCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedTerminalRoutes,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedCurrentTerminalRoutes,
        [Parameter(Mandatory)][ValidateRange(0, 1000)][int]$ReviewedCurrentPacedNextPosts,
        [Parameter(Mandatory)][ValidateSet('single-target')][string]$ReviewedCurrentOwnerMode,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedPrepareModelInvokeCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedPassivePreflightInvokeCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedCacheLookupInvokeCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedCacheFactoryInvokeCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedCachePlaceholderInvokeCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedInspectorArgumentCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedReportPermalinkFixtureCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedReportPermalinkInspectorArgumentCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedProxyBootstrapFixtureCount,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$ReviewedProxyBootstrapInspectorArgumentCount
    )

    $callee = ConvertTo-ThreadsModReleaseToolAst -Label 'negative callee fixture' -Text @'
param($Apk,$SourceApk,$ScratchRoot,$ResolutionPath,$ValidationMode,$ReportPath,$AndroidSdk,$BuildToolsVersion,$Java,$Javac)
'@
    $positiveInvocation = @'
& (Join-Path $PSScriptRoot 'Test-PatchedApk.ps1') -Apk $a -SourceApk $s -ScratchRoot $x -ResolutionPath $r -ValidationMode $m -ReportPath $p -AndroidSdk $sdk -BuildToolsVersion $bt -Java $j -Javac $jc
'@
    $expectedSet = @([pscustomobject]@{ names = @(
        'Apk','SourceApk','ScratchRoot','ResolutionPath','ValidationMode','ReportPath',
        'AndroidSdk','BuildToolsVersion','Java','Javac') })
    $positiveAst = ConvertTo-ThreadsModReleaseToolAst `
        -Text $positiveInvocation -Label 'positive invocation fixture'
    $null = Assert-ThreadsModReleaseInvocationContract `
        -CallerAst $positiveAst -CalleeAst $callee `
        -TargetScriptName 'Test-PatchedApk.ps1' `
        -ExpectedParameterSets $expectedSet -Label 'positive invocation fixture'

    $invocationNegatives = @(
        [pscustomobject]@{ id='undeclared'; text=$positiveInvocation.Replace('-Javac $jc','-Javac $jc -Unknown $u') },
        [pscustomobject]@{ id='duplicate'; text=$positiveInvocation.Replace('-Javac $jc','-Javac $jc -Java $j') },
        [pscustomobject]@{ id='positional'; text=$positiveInvocation.Replace('-Javac $jc','-Javac $jc $extra') },
        [pscustomobject]@{ id='splat'; text=$positiveInvocation.Replace('-Javac $jc','-Javac $jc @extra') },
        [pscustomobject]@{ id='missing-argument'; text=$positiveInvocation.Replace('-Javac $jc','-Javac') },
        [pscustomobject]@{ id='direct-invocation'; text=$positiveInvocation.Replace("& (Join-Path `$PSScriptRoot 'Test-PatchedApk.ps1')", '.\Test-PatchedApk.ps1') },
        [pscustomobject]@{ id='missing-invocation'; text='param()' },
        [pscustomobject]@{ id='duplicate-invocation'; text=$positiveInvocation + $positiveInvocation }
    )
    $caught = 0
    $unexpectedInvocationPasses = @()
    foreach ($fixture in $invocationNegatives) {
        try {
            $fixtureAst = ConvertTo-ThreadsModReleaseToolAst `
                -Text ([string]$fixture.text) -Label ([string]$fixture.id)
            $null = Assert-ThreadsModReleaseInvocationContract `
                -CallerAst $fixtureAst -CalleeAst $callee `
                -TargetScriptName 'Test-PatchedApk.ps1' `
                -ExpectedParameterSets $expectedSet -Label ([string]$fixture.id)
            $unexpectedInvocationPasses += [string]$fixture.id
        } catch {
            $caught++
        }
    }
    if ($caught -ne $invocationNegatives.Count) {
        throw "Release invocation negative fixtures did not fail closed: $($unexpectedInvocationPasses -join ', ')."
    }

    $wrapper = @"
try {
foreach (`$contract in @(`$resolution.release.requiredDexBridgeFlows)) {
    if ([string]`$resolution.source.versionName -ceq '444.0.0.45.85') {
        if ([string]`$bridgeResult.callerProvenance.automatic.ownerMode -ne '$ReviewedCurrentOwnerMode' ``
                -or [int]`$bridgeResult.callerCallbackEffectTopology.automatic.reviewedTerminalRoutes -ne $ReviewedCurrentTerminalRoutes ``
                -or [int]`$bridgeResult.callerCallbackEffectTopology.automatic.pacedNextPosts -ne $ReviewedCurrentPacedNextPosts) {
            throw 'current evidence'
        }
    } elseif ([string]`$resolution.source.versionName -ceq '415.0.0.26.77') {
        `$legacyBridgeResult = `$bridgeResult
        if ([string]`$legacyBridgeResult.callerProvenance.automatic.ownerMode -ne 'legacy-batch' ``
                -or [int]`$legacyBridgeResult.callerCallbackEffectTopology.automatic.reviewedTerminalRoutes -ne $ReviewedTerminalRoutes ``
                -or [int]`$legacyBridgeResult.callerCallbackEffectTopology.automatic.pacedNextPosts -ne 1) {
            throw 'legacy evidence'
        }
    } else {
        throw 'unreviewed version'
    }
    if ([int]`$bridgeResult.rawCalls.prepareModel -ne $ReviewedPrepareModelInvokeCount ``
            -or [int]`$bridgeResult.rawCalls.passivePreflight -ne $ReviewedPassivePreflightInvokeCount ``
            -or [int]`$bridgeResult.definitions.passivePreflight -ne 1 ``
            -or [int]`$bridgeResult.callerProvenance.automatic.passivePreflight -ne 1 ``
            -or [int]`$bridgeResult.callerProvenance.manual.passivePreflight -ne 0 ``
            -or [int]`$bridgeResult.callerProvenance.bridge.prepareModel -ne $ReviewedPrepareModelInvokeCount ``
            -or [int]`$bridgeResult.callerProvenance.bridge.passivePreflight -ne 0 ``
            -or [int]`$bridgeResult.callerProvenance.other.passivePreflight -ne 0 ``
            -or [int]`$bridgeResult.privateSeamProvenance.cacheLookup -ne $ReviewedCacheLookupInvokeCount ``
            -or [int]`$bridgeResult.privateSeamProvenance.cacheFactory -ne $ReviewedCacheFactoryInvokeCount ``
            -or [int]`$bridgeResult.privateSeamProvenance.cachePlaceholder -ne $ReviewedCachePlaceholderInvokeCount ``
            -or [int]`$bridgeResult.callerCallbackEffectTopology.automatic.terminalCatchRoutes -ne 1 ``
            -or [int]`$bridgeResult.callerCallbackEffectTopology.automatic.startedLatchWrites -ne 1 ``
            -or [int]`$bridgeResult.callerCallbackEffectTopology.automatic.statusCalls -ne 1 ``
            -or [int]`$bridgeResult.callerCallbackEffectTopology.automatic.failureRoutes -ne 1 ``
            -or [int]`$bridgeResult.callerCallbackEffectTopology.automatic.completionSaveCalls -ne 1 ``
            -or [int]`$bridgeResult.callerCallbackEffectTopology.automatic.completionQuarantineBranches -ne 1 ``
            -or [int]`$bridgeResult.callerCallbackEffectTopology.automatic.ownershipReleaseCalls -ne 1 ``
            -or [int]`$bridgeResult.callerCallbackEffectTopology.automatic.successRecordCalls -ne 1 ``
            -or [int]`$bridgeResult.callerCallbackEffectTopology.automatic.waitingClearWrites -ne 1 ``
            -or -not [bool]`$bridgeResult.checks.immutableTargetFlow ``
            -or -not [bool]`$bridgeResult.checks.schedulerEnqueueAcceptance ``
            -or -not [bool]`$bridgeResult.checks.uncertainMutationQuarantine ``
            -or -not [bool]`$bridgeResult.checks.passiveNativePreflight ``
            -or -not [bool]`$bridgeResult.checks.passiveMatchFailClosed ``
            -or -not [bool]`$bridgeResult.checks.callerCallbackEffectTopology) {
        throw 'shared evidence'
    }
}
} finally {}
if ([int]`$dexBridgeFlowFixtureResult.expectedFixtureCount -ne $ReviewedFixtureCount) { throw 'count' }
if (@(`$dexBridgeFlowFixtureResult.fixtures).Count -ne $ReviewedFixtureCount) { throw 'observed count' }
"@
    $harness = @"
function Assert-PositiveEvidence {
    param(`$Result)
    if ([string]`$Result.callerProvenance.automatic.ownerMode -ne 'legacy-batch' ``
            -or [int]`$Result.rawCalls.prepareModel -ne $ReviewedPrepareModelInvokeCount ``
            -or [int]`$Result.rawCalls.passivePreflight -ne $ReviewedPassivePreflightInvokeCount ``
            -or [int]`$Result.definitions.passivePreflight -ne 1 ``
            -or [int]`$Result.callerProvenance.automatic.passivePreflight -ne 1 ``
            -or [int]`$Result.callerProvenance.manual.passivePreflight -ne 0 ``
            -or [int]`$Result.callerProvenance.bridge.prepareModel -ne $ReviewedPrepareModelInvokeCount ``
            -or [int]`$Result.callerProvenance.bridge.passivePreflight -ne 0 ``
            -or [int]`$Result.callerProvenance.other.passivePreflight -ne 0 ``
            -or [int]`$Result.privateSeamProvenance.cacheLookup -ne $ReviewedCacheLookupInvokeCount ``
            -or [int]`$Result.privateSeamProvenance.cacheFactory -ne $ReviewedCacheFactoryInvokeCount ``
            -or [int]`$Result.privateSeamProvenance.cachePlaceholder -ne $ReviewedCachePlaceholderInvokeCount ``
            -or -not [bool]`$Result.checks.passiveNativePreflight ``
            -or -not [bool]`$Result.checks.passiveMatchFailClosed ``
            -or [int]`$Result.callerCallbackEffectTopology.automatic.reviewedTerminalRoutes -ne $ReviewedTerminalRoutes ``
            -or [int]`$Result.callerCallbackEffectTopology.automatic.pacedNextPosts -ne 1 ``
            -or [int]`$Result.callerCallbackEffectTopology.automatic.terminalCatchRoutes -ne 1 ``
            -or [int]`$Result.callerCallbackEffectTopology.automatic.startedLatchWrites -ne 1 ``
            -or [int]`$Result.callerCallbackEffectTopology.automatic.statusCalls -ne 1 ``
            -or [int]`$Result.callerCallbackEffectTopology.automatic.failureRoutes -ne 1 ``
            -or [int]`$Result.callerCallbackEffectTopology.automatic.completionSaveCalls -ne 1 ``
            -or [int]`$Result.callerCallbackEffectTopology.automatic.completionQuarantineBranches -ne 1 ``
            -or [int]`$Result.callerCallbackEffectTopology.automatic.ownershipReleaseCalls -ne 1 ``
            -or [int]`$Result.callerCallbackEffectTopology.automatic.successRecordCalls -ne 1 ``
            -or [int]`$Result.callerCallbackEffectTopology.automatic.waitingClearWrites -ne 1) {
        throw 'legacy fixture'
    }
}
function Assert-SingleTargetPositiveEvidence {
    param(`$CurrentResult)
    if ([string]`$CurrentResult.callerProvenance.automatic.ownerMode -ne '$ReviewedCurrentOwnerMode' ``
            -or [int]`$CurrentResult.rawCalls.prepareModel -ne $ReviewedPrepareModelInvokeCount ``
            -or [int]`$CurrentResult.rawCalls.passivePreflight -ne $ReviewedPassivePreflightInvokeCount ``
            -or [int]`$CurrentResult.definitions.passivePreflight -ne 1 ``
            -or [int]`$CurrentResult.callerProvenance.automatic.passivePreflight -ne 1 ``
            -or [int]`$CurrentResult.callerProvenance.manual.passivePreflight -ne 0 ``
            -or [int]`$CurrentResult.callerProvenance.bridge.prepareModel -ne $ReviewedPrepareModelInvokeCount ``
            -or [int]`$CurrentResult.callerProvenance.bridge.passivePreflight -ne 0 ``
            -or [int]`$CurrentResult.callerProvenance.other.passivePreflight -ne 0 ``
            -or [int]`$CurrentResult.privateSeamProvenance.cacheLookup -ne $ReviewedCacheLookupInvokeCount ``
            -or [int]`$CurrentResult.privateSeamProvenance.cacheFactory -ne $ReviewedCacheFactoryInvokeCount ``
            -or [int]`$CurrentResult.privateSeamProvenance.cachePlaceholder -ne $ReviewedCachePlaceholderInvokeCount ``
            -or -not [bool]`$CurrentResult.checks.passiveNativePreflight ``
            -or -not [bool]`$CurrentResult.checks.passiveMatchFailClosed ``
            -or [int]`$CurrentResult.callerCallbackEffectTopology.automatic.reviewedTerminalRoutes -ne $ReviewedCurrentTerminalRoutes ``
            -or [int]`$CurrentResult.callerCallbackEffectTopology.automatic.terminalCatchRoutes -ne 1 ``
            -or [int]`$CurrentResult.callerCallbackEffectTopology.automatic.pacedNextPosts -ne $ReviewedCurrentPacedNextPosts ``
            -or [int]`$CurrentResult.callerCallbackEffectTopology.automatic.startedLatchWrites -ne 1 ``
            -or [int]`$CurrentResult.callerCallbackEffectTopology.automatic.statusCalls -ne 1 ``
            -or [int]`$CurrentResult.callerCallbackEffectTopology.automatic.failureRoutes -ne 1 ``
            -or [int]`$CurrentResult.callerCallbackEffectTopology.automatic.completionSaveCalls -ne 1 ``
            -or [int]`$CurrentResult.callerCallbackEffectTopology.automatic.completionQuarantineBranches -ne 1 ``
            -or [int]`$CurrentResult.callerCallbackEffectTopology.automatic.ownershipReleaseCalls -ne 1 ``
            -or [int]`$CurrentResult.callerCallbackEffectTopology.automatic.successRecordCalls -ne 1 ``
            -or [int]`$CurrentResult.callerCallbackEffectTopology.automatic.waitingClearWrites -ne 1 ``
            -or -not [bool]`$CurrentResult.checks.immutableTargetFlow ``
            -or -not [bool]`$CurrentResult.checks.schedulerEnqueueAcceptance ``
            -or -not [bool]`$CurrentResult.checks.uncertainMutationQuarantine ``
            -or -not [bool]`$CurrentResult.checks.callerCallbackEffectTopology) {
        throw 'current fixture'
    }
}
if ([int]`$expectedFixtureCount -ne $ReviewedFixtureCount) { throw 'count' }
if (`$results.Count -ne $ReviewedFixtureCount) { throw 'observed count' }
"@
    $wrapperMissingObservedCount = $wrapper.Replace(
        "if (@(`$dexBridgeFlowFixtureResult.fixtures).Count -ne $ReviewedFixtureCount) { throw 'observed count' }", '')
    $wrapperAst = ConvertTo-ThreadsModReleaseToolAst `
        -Text $wrapper -Label 'positive evidence wrapper fixture'
    $harnessAst = ConvertTo-ThreadsModReleaseToolAst `
        -Text $harness -Label 'positive evidence harness fixture'
    $null = Assert-ThreadsModReleaseEvidenceContract `
        -ReleaseWrapperAst $wrapperAst -FixtureHarnessAst $harnessAst `
        -ReviewedFixtureCount $ReviewedFixtureCount `
        -ReviewedTerminalRoutes $ReviewedTerminalRoutes `
        -ReviewedCurrentTerminalRoutes $ReviewedCurrentTerminalRoutes `
        -ReviewedCurrentPacedNextPosts $ReviewedCurrentPacedNextPosts `
        -ReviewedCurrentOwnerMode $ReviewedCurrentOwnerMode `
        -ReviewedPrepareModelInvokeCount $ReviewedPrepareModelInvokeCount `
        -ReviewedPassivePreflightInvokeCount $ReviewedPassivePreflightInvokeCount `
        -ReviewedCacheLookupInvokeCount $ReviewedCacheLookupInvokeCount `
        -ReviewedCacheFactoryInvokeCount $ReviewedCacheFactoryInvokeCount `
        -ReviewedCachePlaceholderInvokeCount $ReviewedCachePlaceholderInvokeCount

    $evidenceNegatives = @(
        [pscustomobject]@{ id='divergent-count'; wrapper=$wrapper.Replace("expectedFixtureCount -ne $ReviewedFixtureCount", "expectedFixtureCount -ne $($ReviewedFixtureCount + 1)"); harness=$harness; reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='nonliteral-count'; wrapper=$wrapper; harness=$harness.Replace("expectedFixtureCount -ne $ReviewedFixtureCount", 'expectedFixtureCount -ne $reviewed'); reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='missing-count'; wrapper=$wrapperMissingObservedCount; harness=$harness; reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='duplicate-count'; wrapper=$wrapper + "if (@(`$dexBridgeFlowFixtureResult.fixtures).Count -ne $ReviewedFixtureCount) {}`n"; harness=$harness; reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='resolution-count-drift'; wrapper=$wrapper; harness=$harness; reviewed=($ReviewedFixtureCount + 1) },
        [pscustomobject]@{ id='divergent-current-terminal'; wrapper=$wrapper.Replace("`$bridgeResult.callerCallbackEffectTopology.automatic.reviewedTerminalRoutes -ne $ReviewedCurrentTerminalRoutes", "`$bridgeResult.callerCallbackEffectTopology.automatic.reviewedTerminalRoutes -ne $($ReviewedCurrentTerminalRoutes + 1)"); harness=$harness; reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='divergent-current-paced'; wrapper=$wrapper.Replace("`$bridgeResult.callerCallbackEffectTopology.automatic.pacedNextPosts -ne $ReviewedCurrentPacedNextPosts", "`$bridgeResult.callerCallbackEffectTopology.automatic.pacedNextPosts -ne $($ReviewedCurrentPacedNextPosts + 1)"); harness=$harness; reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='divergent-current-status'; wrapper=$wrapper; harness=$harness.Replace('$CurrentResult.callerCallbackEffectTopology.automatic.statusCalls -ne 1', '$CurrentResult.callerCallbackEffectTopology.automatic.statusCalls -ne 2'); reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='divergent-current-catch'; wrapper=$wrapper.Replace('$bridgeResult.callerCallbackEffectTopology.automatic.terminalCatchRoutes -ne 1', '$bridgeResult.callerCallbackEffectTopology.automatic.terminalCatchRoutes -ne 2'); harness=$harness; reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='correlated-noncanonical-number'; wrapper=$wrapper.Replace('$bridgeResult.callerCallbackEffectTopology.automatic.statusCalls -ne 1', '$bridgeResult.callerCallbackEffectTopology.automatic.statusCalls -ne 1.0'); harness=$harness.Replace('$CurrentResult.callerCallbackEffectTopology.automatic.statusCalls -ne 1', '$CurrentResult.callerCallbackEffectTopology.automatic.statusCalls -ne 1.0'); reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='divergent-current-boolean'; wrapper=$wrapper; harness=$harness.Replace('$CurrentResult.checks.immutableTargetFlow', '$CurrentResult.checks.directIdCacheFallback'); reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='divergent-shared-cache'; wrapper=$wrapper; harness=$harness.Replace("`$CurrentResult.privateSeamProvenance.cacheLookup -ne $ReviewedCacheLookupInvokeCount", "`$CurrentResult.privateSeamProvenance.cacheLookup -ne $($ReviewedCacheLookupInvokeCount + 1)"); reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='missing-shared-passive'; wrapper=$wrapper.Replace('$bridgeResult.rawCalls.passivePreflight', '$bridgeResult.rawCalls.passivePreflightMissing'); harness=$harness; reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='nonliteral-shared-prepare'; wrapper=$wrapper; harness=$harness.Replace("`$CurrentResult.callerProvenance.bridge.prepareModel -ne $ReviewedPrepareModelInvokeCount", '$CurrentResult.callerProvenance.bridge.prepareModel -ne $reviewedPrepare'); reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='duplicate-shared-cache'; wrapper=$wrapper + "if ([int]`$bridgeResult.privateSeamProvenance.cacheLookup -ne $ReviewedCacheLookupInvokeCount) { throw 'duplicate shared cache' }`n"; harness=$harness; reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='legacy-shared-cache-drift'; wrapper=$wrapper; harness=$harness.Replace("`$Result.privateSeamProvenance.cacheFactory -ne $ReviewedCacheFactoryInvokeCount", "`$Result.privateSeamProvenance.cacheFactory -ne $($ReviewedCacheFactoryInvokeCount + 1)"); reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='divergent-shared-passive-check'; wrapper=$wrapper; harness=$harness.Replace('$CurrentResult.checks.passiveNativePreflight', '$CurrentResult.checks.directIdCacheFallback'); reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='divergent-current-owner'; wrapper=$wrapper.Replace("`$bridgeResult.callerProvenance.automatic.ownerMode -ne '$ReviewedCurrentOwnerMode'", "`$bridgeResult.callerProvenance.automatic.ownerMode -ne 'legacy-batch'"); harness=$harness; reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='nonliteral-current-owner'; wrapper=$wrapper.Replace("ownerMode -ne '$ReviewedCurrentOwnerMode'", 'ownerMode -ne $reviewedMode'); harness=$harness; reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='missing-current-owner'; wrapper=$wrapper.Replace('$bridgeResult.callerProvenance.automatic.ownerMode', '$bridgeResult.callerProvenance.automatic.ownerModeMissing'); harness=$harness; reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='duplicate-current-owner'; wrapper=$wrapper + "if ([string]`$bridgeResult.callerProvenance.automatic.ownerMode -ne '$ReviewedCurrentOwnerMode') { throw 'duplicate' }`n"; harness=$harness; reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='legacy-terminal-drift'; wrapper=$wrapper; harness=$harness.Replace("`$Result.callerCallbackEffectTopology.automatic.reviewedTerminalRoutes -ne $ReviewedTerminalRoutes", "`$Result.callerCallbackEffectTopology.automatic.reviewedTerminalRoutes -ne $($ReviewedTerminalRoutes + 1)"); reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='legacy-wrapper-drift'; wrapper=$wrapper.Replace("`$legacyBridgeResult.callerCallbackEffectTopology.automatic.reviewedTerminalRoutes -ne $ReviewedTerminalRoutes", "`$legacyBridgeResult.callerCallbackEffectTopology.automatic.reviewedTerminalRoutes -ne $($ReviewedTerminalRoutes + 1)"); harness=$harness; reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='current-evidence-dead-scriptblock'; wrapper=$wrapper; harness=$harness.Replace('function Assert-SingleTargetPositiveEvidence {', "function Assert-SingleTargetPositiveEvidence {`n    `$unusedEvidence = {").Replace("        throw 'current fixture'`n    }`n}", "        throw 'current fixture'`n    }`n    }`n}"); reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='shared-evidence-nested'; wrapper=$wrapper.Replace('    if ([int]$bridgeResult.rawCalls.prepareModel', "    if (`$false) {`n    if ([int]`$bridgeResult.rawCalls.prepareModel").Replace("        throw 'shared evidence'`n    }`n}", "        throw 'shared evidence'`n    }`n    }`n}"); harness=$harness; reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='current-nonthrow-guard'; wrapper=$wrapper.Replace("throw 'current evidence'", '$null = 1'); harness=$harness; reviewed=$ReviewedFixtureCount },
        [pscustomobject]@{ id='swapped-version-lanes'; wrapper=$wrapper.Replace("'444.0.0.45.85'", "'version-marker'").Replace("'415.0.0.26.77'", "'444.0.0.45.85'").Replace("'version-marker'", "'415.0.0.26.77'"); harness=$harness; reviewed=$ReviewedFixtureCount }
    )
    $evidenceCaught = 0
    $unexpectedEvidencePasses = @()
    foreach ($fixture in $evidenceNegatives) {
        $negativeWrapperAst = ConvertTo-ThreadsModReleaseToolAst `
            -Text ([string]$fixture.wrapper) -Label ([string]$fixture.id)
        $negativeHarnessAst = ConvertTo-ThreadsModReleaseToolAst `
            -Text ([string]$fixture.harness) -Label ([string]$fixture.id)
        try {
            $null = Assert-ThreadsModReleaseEvidenceContract `
                -ReleaseWrapperAst $negativeWrapperAst `
                -FixtureHarnessAst $negativeHarnessAst `
                -ReviewedFixtureCount ([int]$fixture.reviewed) `
                -ReviewedTerminalRoutes $ReviewedTerminalRoutes `
                -ReviewedCurrentTerminalRoutes $ReviewedCurrentTerminalRoutes `
                -ReviewedCurrentPacedNextPosts $ReviewedCurrentPacedNextPosts `
                -ReviewedCurrentOwnerMode $ReviewedCurrentOwnerMode `
                -ReviewedPrepareModelInvokeCount $ReviewedPrepareModelInvokeCount `
                -ReviewedPassivePreflightInvokeCount $ReviewedPassivePreflightInvokeCount `
                -ReviewedCacheLookupInvokeCount $ReviewedCacheLookupInvokeCount `
                -ReviewedCacheFactoryInvokeCount $ReviewedCacheFactoryInvokeCount `
                -ReviewedCachePlaceholderInvokeCount $ReviewedCachePlaceholderInvokeCount
            $unexpectedEvidencePasses += [string]$fixture.id
        } catch {
            $evidenceCaught++
        }
    }
    if ($evidenceCaught -ne $evidenceNegatives.Count) {
        throw "Release evidence negative fixtures did not fail closed: $($unexpectedEvidencePasses -join ', ')."
    }

    $bindingWrapper = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot 'Test-PatchedApk.ps1'), [Text.Encoding]::UTF8).
        Replace("`r`n", "`n")
    $bindingHarness = [IO.File]::ReadAllText(
        (Join-Path $PSScriptRoot 'Test-DexBridgeFlowInspector.ps1'),
        [Text.Encoding]::UTF8).Replace("`r`n", "`n")
    $bindingWrapperAst = ConvertTo-ThreadsModReleaseToolAst `
        -Text $bindingWrapper -Label 'positive bridge inspector binding wrapper fixture'
    $bindingHarnessAst = ConvertTo-ThreadsModReleaseToolAst `
        -Text $bindingHarness -Label 'positive bridge inspector binding harness fixture'
    $null = Assert-ThreadsModDexBridgeInspectorBindingContract `
        -ReleaseWrapperAst $bindingWrapperAst `
        -FixtureHarnessAst $bindingHarnessAst `
        -ReviewedArgumentCount $ReviewedInspectorArgumentCount

    $wrapperSemanticSubstitution = Set-ThreadsModExactTextMutation `
        -Text $bindingWrapper `
        -Before '        [string]$contract.blockMethodName,' `
        -After '        [string]$contract.unreviewedBlockMethodName,' `
        -Label 'bridge-binding wrapper semantic substitution'
    $harnessSemanticSubstitution = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness `
        -Before '    [string]$bridgeFlowContract.blockMethodName,' `
        -After '    [string]$bridgeFlowContract.unreviewedBlockMethodName,' `
        -Label 'bridge-binding harness semantic substitution'
    $correlatedWrapperSubstitution = $wrapperSemanticSubstitution
    $correlatedHarnessSubstitution = $harnessSemanticSubstitution
    $wrapperReorder = Set-ThreadsModExactTextMutation `
        -Text $bindingWrapper `
        -Before "        [string]`$contract.blockMethodName,`n        [string]`$contract.blockResolvedMethodName," `
        -After "        [string]`$contract.blockResolvedMethodName,`n        [string]`$contract.blockMethodName," `
        -Label 'bridge-binding wrapper order mutation'
    $harnessReorder = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness `
        -Before "    [string]`$bridgeFlowContract.blockMethodName,`n    [string]`$bridgeFlowContract.blockResolvedMethodName," `
        -After "    [string]`$bridgeFlowContract.blockResolvedMethodName,`n    [string]`$bridgeFlowContract.blockMethodName," `
        -Label 'bridge-binding harness order mutation'
    $wrapperCommandSubstitution = Set-ThreadsModExactTextMutation `
        -Text $bindingWrapper `
        -Before '    $bridgeLines = @(Invoke-Captured -Command $Java -Arguments @(' `
        -After '    $bridgeLines = @(Write-Output -Command $Java -Arguments @(' `
        -Label 'bridge-binding wrapper command substitution'
    $wrapperExtraArgument = Set-ThreadsModExactTextMutation `
        -Text $bindingWrapper `
        -Before '        [string]$inlineSymbols.authorUsernameMethod))' `
        -After "        [string]`$inlineSymbols.authorUsernameMethod,`n        [string]`$contract.ownerClassDescriptor))" `
        -Label 'bridge-binding wrapper extra argument'
    $harnessExtraArgument = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness `
        -Before '    [string]$resolution.inlineControls.symbols.authorUsernameMethod)' `
        -After "    [string]`$resolution.inlineControls.symbols.authorUsernameMethod,`n    [string]`$bridgeFlowContract.ownerClassDescriptor)" `
        -Label 'bridge-binding harness extra argument'
    $wrapperMisplaced = Set-ThreadsModExactTextMutation `
        -Text $bindingWrapper `
        -Before '    $bridgeLines = @(Invoke-Captured -Command $Java -Arguments @(' `
        -After "    if (`$true) {`n        `$bridgeLines = @(Invoke-Captured -Command `$Java -Arguments @(" `
        -Label 'bridge-binding wrapper misplaced start'
    $wrapperMisplaced = Set-ThreadsModExactTextMutation `
        -Text $wrapperMisplaced `
        -Before '        [string]$inlineSymbols.authorUsernameMethod))' `
        -After "        [string]`$inlineSymbols.authorUsernameMethod))`n    }" `
        -Label 'bridge-binding wrapper misplaced end'
    $harnessMisplaced = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness -Before '$currentArguments = @(' `
        -After "if (`$true) {`n    `$currentArguments = @(" `
        -Label 'bridge-binding harness misplaced start'
    $harnessMisplaced = Set-ThreadsModExactTextMutation `
        -Text $harnessMisplaced `
        -Before '    [string]$resolution.inlineControls.symbols.authorUsernameMethod)' `
        -After "    [string]`$resolution.inlineControls.symbols.authorUsernameMethod)`n}" `
        -Label 'bridge-binding harness misplaced end'
    $currentPositiveCommonArguments = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness `
        -Before "    '-cp', `$helperClasspath, 'DexBridgeFlowInspector', `$currentPositiveApk) ```n    + `$currentArguments)" `
        -After "    '-cp', `$helperClasspath, 'DexBridgeFlowInspector', `$currentPositiveApk) ```n    + `$commonArguments)" `
        -Label 'bridge-binding current positive common arguments'
    $currentNegativeCommonArguments = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness `
        -Before "        '-cp', `$helperClasspath, 'DexBridgeFlowInspector', `$fixtureApk) ```n        + `$currentArguments)" `
        -After "        '-cp', `$helperClasspath, 'DexBridgeFlowInspector', `$fixtureApk) ```n        + `$commonArguments)" `
        -Label 'bridge-binding current negative common arguments'
    $legacyPositiveCurrentArguments = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness `
        -Before "    '-cp', `$helperClasspath, 'DexBridgeFlowInspector', `$positiveApk) + `$commonArguments)" `
        -After "    '-cp', `$helperClasspath, 'DexBridgeFlowInspector', `$positiveApk) + `$currentArguments)" `
        -Label 'bridge-binding legacy positive current arguments'
    $legacyNegativeCurrentArguments = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness `
        -Before "        '-cp', `$helperClasspath, 'DexBridgeFlowInspector', `$fixtureApk) + `$commonArguments)" `
        -After "        '-cp', `$helperClasspath, 'DexBridgeFlowInspector', `$fixtureApk) + `$currentArguments)" `
        -Label 'bridge-binding legacy negative current arguments'
    $wrongCurrentApk = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness `
        -Before "    '-cp', `$helperClasspath, 'DexBridgeFlowInspector', `$currentPositiveApk) ``" `
        -After "    '-cp', `$helperClasspath, 'DexBridgeFlowInspector', `$positiveApk) ``" `
        -Label 'bridge-binding current positive wrong APK'
    $wrongCurrentNegativeCollection = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness `
        -Before "foreach (`$fixture in `$singleTargetNegativeFixtures) {`n    `$fixtureId = [string]`$fixture.id" `
        -After "foreach (`$fixture in `$negativeFixtures) {`n    `$fixtureId = [string]`$fixture.id" `
        -Label 'bridge-binding current negative collection substitution'
    $wrongCurrentProbeCommand = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness `
        -Before '$currentPositiveProbe = Invoke-ProbeNative -Command $Java' `
        -After '$currentPositiveProbe = Write-Output -Command $Java' `
        -Label 'bridge-binding current probe command substitution'
    $misplacedCurrentProbe = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness `
        -Before '$currentPositiveProbe = Invoke-ProbeNative -Command $Java -Arguments (@(' `
        -After "if (`$true) {`n    `$currentPositiveProbe = Invoke-ProbeNative -Command `$Java -Arguments (@(" `
        -Label 'bridge-binding current probe misplaced start'
    $misplacedCurrentProbe = Set-ThreadsModExactTextMutation `
        -Text $misplacedCurrentProbe `
        -Before "    '-cp', `$helperClasspath, 'DexBridgeFlowInspector', `$currentPositiveApk) ```n    + `$currentArguments)" `
        -After "        '-cp', `$helperClasspath, 'DexBridgeFlowInspector', `$currentPositiveApk) ```n        + `$currentArguments)`n}" `
        -Label 'bridge-binding current probe misplaced end'
    $mutatedCurrentArguments = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness `
        -Before "if (`$currentArguments.Count -ne 27) {`n    throw 'Current bridge-flow generated-Smali argument binding count drifted.'`n}" `
        -After "if (`$currentArguments.Count -ne 27) {`n    throw 'Current bridge-flow generated-Smali argument binding count drifted.'`n}`n`$currentArguments.SetValue([string]`$bridgeFlowContract.ownerClassDescriptor, 0)" `
        -Label 'bridge-binding mutable current arguments'
    $indirectCurrentArgumentsMutation = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness `
        -Before '$currentPositiveProbe = Invoke-ProbeNative -Command $Java' `
        -After "Set-Variable -Name currentArguments -Value `$commonArguments`n`$currentPositiveProbe = Invoke-ProbeNative -Command `$Java" `
        -Label 'bridge-binding indirect current arguments mutation'
    $wrongCurrentParseProbe = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness `
        -Before '-Lines $currentPositiveProbe.lines -FixtureId ''positive-single-target''' `
        -After '-Lines $positiveProbe.lines -FixtureId ''positive-single-target''' `
        -Label 'bridge-binding current positive parse substitution'
    $wrongCurrentAssertionResult = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness `
        -Before '    -CurrentResult $currentPositiveResult `' `
        -After '    -CurrentResult $positiveResult `' `
        -Label 'bridge-binding current positive assertion substitution'
    $wrongWrapperParse = Set-ThreadsModExactTextMutation `
        -Text $bindingWrapper `
        -Before '    $bridgeResult = $bridgeLines[-1] | ConvertFrom-Json' `
        -After '    $bridgeResult = $otherLines[-1] | ConvertFrom-Json' `
        -Label 'bridge-binding wrapper parse substitution'
    $extraBridgeLinesRead = Set-ThreadsModExactTextMutation `
        -Text $bindingWrapper `
        -Before '    $bridgeResult = $bridgeLines[-1] | ConvertFrom-Json' `
        -After "    `$null = `$bridgeLines.Count`n    `$bridgeResult = `$bridgeLines[-1] | ConvertFrom-Json" `
        -Label 'bridge-binding bridgeLines escape'
    $extraSymbolsRead = Set-ThreadsModExactTextMutation `
        -Text $bindingWrapper `
        -Before '    $bridgeLines = @(Invoke-Captured -Command $Java -Arguments @(' `
        -After "    `$null = `$symbols`n    `$bridgeLines = @(Invoke-Captured -Command `$Java -Arguments @(" `
        -Label 'bridge-binding symbols escape'
    $legacyLiteralSubstitution = Set-ThreadsModExactTextMutation `
        -Text $bindingHarness `
        -Before "    'Lthreadsmod/autoblock/ThreadsBlockBridge;'," `
        -After "    'Lthreadsmod/autoblock/UnreviewedBridge;'," `
        -Label 'bridge-binding legacy literal substitution'

    $bindingNegatives = @(
        [pscustomobject]@{ id='wrapper-substitution'; wrapper=$wrapperSemanticSubstitution; harness=$bindingHarness },
        [pscustomobject]@{ id='harness-substitution'; wrapper=$bindingWrapper; harness=$harnessSemanticSubstitution },
        [pscustomobject]@{ id='correlated-substitution'; wrapper=$correlatedWrapperSubstitution; harness=$correlatedHarnessSubstitution },
        [pscustomobject]@{ id='wrapper-reorder'; wrapper=$wrapperReorder; harness=$bindingHarness },
        [pscustomobject]@{ id='harness-reorder'; wrapper=$bindingWrapper; harness=$harnessReorder },
        [pscustomobject]@{ id='wrapper-command-substitution'; wrapper=$wrapperCommandSubstitution; harness=$bindingHarness },
        [pscustomobject]@{ id='wrapper-extra-argument'; wrapper=$wrapperExtraArgument; harness=$bindingHarness },
        [pscustomobject]@{ id='harness-extra-argument'; wrapper=$bindingWrapper; harness=$harnessExtraArgument },
        [pscustomobject]@{ id='wrapper-misplaced'; wrapper=$wrapperMisplaced; harness=$bindingHarness },
        [pscustomobject]@{ id='harness-misplaced'; wrapper=$bindingWrapper; harness=$harnessMisplaced },
        [pscustomobject]@{ id='current-positive-common-arguments'; wrapper=$bindingWrapper; harness=$currentPositiveCommonArguments },
        [pscustomobject]@{ id='current-negative-common-arguments'; wrapper=$bindingWrapper; harness=$currentNegativeCommonArguments },
        [pscustomobject]@{ id='legacy-positive-current-arguments'; wrapper=$bindingWrapper; harness=$legacyPositiveCurrentArguments },
        [pscustomobject]@{ id='legacy-negative-current-arguments'; wrapper=$bindingWrapper; harness=$legacyNegativeCurrentArguments },
        [pscustomobject]@{ id='wrong-current-apk'; wrapper=$bindingWrapper; harness=$wrongCurrentApk },
        [pscustomobject]@{ id='wrong-current-negative-collection'; wrapper=$bindingWrapper; harness=$wrongCurrentNegativeCollection },
        [pscustomobject]@{ id='wrong-current-probe-command'; wrapper=$bindingWrapper; harness=$wrongCurrentProbeCommand },
        [pscustomobject]@{ id='misplaced-current-probe'; wrapper=$bindingWrapper; harness=$misplacedCurrentProbe },
        [pscustomobject]@{ id='mutable-current-arguments'; wrapper=$bindingWrapper; harness=$mutatedCurrentArguments },
        [pscustomobject]@{ id='indirect-current-arguments-mutation'; wrapper=$bindingWrapper; harness=$indirectCurrentArgumentsMutation },
        [pscustomobject]@{ id='wrong-current-parse-probe'; wrapper=$bindingWrapper; harness=$wrongCurrentParseProbe },
        [pscustomobject]@{ id='wrong-current-assertion-result'; wrapper=$bindingWrapper; harness=$wrongCurrentAssertionResult },
        [pscustomobject]@{ id='wrong-wrapper-parse'; wrapper=$wrongWrapperParse; harness=$bindingHarness },
        [pscustomobject]@{ id='bridgeLines-escape'; wrapper=$extraBridgeLinesRead; harness=$bindingHarness },
        [pscustomobject]@{ id='symbols-escape'; wrapper=$extraSymbolsRead; harness=$bindingHarness },
        [pscustomobject]@{ id='legacy-literal-substitution'; wrapper=$bindingWrapper; harness=$legacyLiteralSubstitution }
    )
    $bindingCaught = 0
    $unexpectedBindingPasses = @()
    foreach ($fixture in $bindingNegatives) {
        $negativeWrapperAst = ConvertTo-ThreadsModReleaseToolAst `
            -Text ([string]$fixture.wrapper) -Label ([string]$fixture.id)
        $negativeHarnessAst = ConvertTo-ThreadsModReleaseToolAst `
            -Text ([string]$fixture.harness) -Label ([string]$fixture.id)
        try {
            $null = Assert-ThreadsModDexBridgeInspectorBindingContract `
                -ReleaseWrapperAst $negativeWrapperAst `
                -FixtureHarnessAst $negativeHarnessAst `
                -ReviewedArgumentCount $ReviewedInspectorArgumentCount
            $unexpectedBindingPasses += [string]$fixture.id
        } catch {
            $bindingCaught++
        }
    }
    if ($bindingCaught -ne $bindingNegatives.Count) {
        throw "Bridge inspector binding negative fixtures did not fail closed: $($unexpectedBindingPasses -join ', ')."
    }

$reportPermalinkWrapper = @"
if ([int]`$dexReportPermalinkFlowFixtureResult.expectedFixtureCount -ne $ReviewedReportPermalinkFixtureCount) {}
if (@(`$dexReportPermalinkFlowFixtureResult.fixtures).Count -ne $ReviewedReportPermalinkFixtureCount) {}
if ([int]`$dexReportPermalinkFlowFixtureResult.inspectorArgumentCount -ne $ReviewedReportPermalinkInspectorArgumentCount) {}
if ([int]`$dexReportPermalinkFlow.rowControl.ufiButtonDefaultMask -ne 63232) {}
if (-not [bool]`$dexReportPermalinkFlow.checks.rowDecoratedModifierFlow) {}
if (-not [bool]`$dexReportPermalinkFlow.checks.rowUfiDefaultMaskExact) {}
"@
    $reportPermalinkHarness = @"
if ([int]`$expectedFixtureCount -ne $ReviewedReportPermalinkFixtureCount) {}
if (`$results.Count -ne $ReviewedReportPermalinkFixtureCount) {}
if ([int]`$inspectorArgumentCount -ne $ReviewedReportPermalinkInspectorArgumentCount) {}
if ([int]`$positiveResult.rowControl.ufiButtonDefaultMask -ne 63232) {}
if (-not [bool]`$positiveResult.checks.rowDecoratedModifierFlow) {}
if (-not [bool]`$positiveResult.checks.rowUfiDefaultMaskExact) {}
"@
    $reportPermalinkWrapperAst = ConvertTo-ThreadsModReleaseToolAst `
        -Text $reportPermalinkWrapper -Label 'positive report-permalink evidence wrapper fixture'
    $reportPermalinkHarnessAst = ConvertTo-ThreadsModReleaseToolAst `
        -Text $reportPermalinkHarness -Label 'positive report-permalink evidence harness fixture'
    $null = Assert-ThreadsModReportPermalinkEvidenceContract `
        -ReleaseWrapperAst $reportPermalinkWrapperAst `
        -FixtureHarnessAst $reportPermalinkHarnessAst `
        -ReviewedFixtureCount $ReviewedReportPermalinkFixtureCount `
        -ReviewedInspectorArgumentCount $ReviewedReportPermalinkInspectorArgumentCount
    $reportPermalinkEvidenceNegatives = @(
        [pscustomobject]@{ id='report-permalink-divergent-count'; wrapper=$reportPermalinkWrapper.Replace("expectedFixtureCount -ne $ReviewedReportPermalinkFixtureCount", "expectedFixtureCount -ne $($ReviewedReportPermalinkFixtureCount + 1)"); harness=$reportPermalinkHarness; fixtureCount=$ReviewedReportPermalinkFixtureCount; argumentCount=$ReviewedReportPermalinkInspectorArgumentCount },
        [pscustomobject]@{ id='report-permalink-nonliteral-count'; wrapper=$reportPermalinkWrapper; harness=$reportPermalinkHarness.Replace("expectedFixtureCount -ne $ReviewedReportPermalinkFixtureCount", 'expectedFixtureCount -ne $reviewed'); fixtureCount=$ReviewedReportPermalinkFixtureCount; argumentCount=$ReviewedReportPermalinkInspectorArgumentCount },
        [pscustomobject]@{ id='report-permalink-divergent-inspector-count'; wrapper=$reportPermalinkWrapper.Replace("inspectorArgumentCount -ne $ReviewedReportPermalinkInspectorArgumentCount", "inspectorArgumentCount -ne $($ReviewedReportPermalinkInspectorArgumentCount + 1)"); harness=$reportPermalinkHarness; fixtureCount=$ReviewedReportPermalinkFixtureCount; argumentCount=$ReviewedReportPermalinkInspectorArgumentCount },
        [pscustomobject]@{ id='report-permalink-resolution-count-drift'; wrapper=$reportPermalinkWrapper; harness=$reportPermalinkHarness; fixtureCount=($ReviewedReportPermalinkFixtureCount + 1); argumentCount=$ReviewedReportPermalinkInspectorArgumentCount },
        [pscustomobject]@{ id='report-permalink-resolution-argument-drift'; wrapper=$reportPermalinkWrapper; harness=$reportPermalinkHarness; fixtureCount=$ReviewedReportPermalinkFixtureCount; argumentCount=($ReviewedReportPermalinkInspectorArgumentCount + 1) },
        [pscustomobject]@{ id='report-permalink-duplicate-observed-count'; wrapper=$reportPermalinkWrapper + "if (@(`$dexReportPermalinkFlowFixtureResult.fixtures).Count -ne $ReviewedReportPermalinkFixtureCount) {}`n"; harness=$reportPermalinkHarness; fixtureCount=$ReviewedReportPermalinkFixtureCount; argumentCount=$ReviewedReportPermalinkInspectorArgumentCount },
        [pscustomobject]@{ id='report-permalink-divergent-ufi-mask'; wrapper=$reportPermalinkWrapper.Replace('ufiButtonDefaultMask -ne 63232', 'ufiButtonDefaultMask -ne 62976'); harness=$reportPermalinkHarness; fixtureCount=$ReviewedReportPermalinkFixtureCount; argumentCount=$ReviewedReportPermalinkInspectorArgumentCount },
        [pscustomobject]@{ id='report-permalink-missing-modifier-flow'; wrapper=$reportPermalinkWrapper.Replace('rowDecoratedModifierFlow', 'rowDecoratedModifierFlowMissing'); harness=$reportPermalinkHarness; fixtureCount=$ReviewedReportPermalinkFixtureCount; argumentCount=$ReviewedReportPermalinkInspectorArgumentCount }
    )
    $reportPermalinkEvidenceCaught = 0
    foreach ($fixture in $reportPermalinkEvidenceNegatives) {
        try {
            $negativeWrapperAst = ConvertTo-ThreadsModReleaseToolAst `
                -Text ([string]$fixture.wrapper) -Label ([string]$fixture.id)
            $negativeHarnessAst = ConvertTo-ThreadsModReleaseToolAst `
                -Text ([string]$fixture.harness) -Label ([string]$fixture.id)
            $null = Assert-ThreadsModReportPermalinkEvidenceContract `
                -ReleaseWrapperAst $negativeWrapperAst `
                -FixtureHarnessAst $negativeHarnessAst `
                -ReviewedFixtureCount ([int]$fixture.fixtureCount) `
                -ReviewedInspectorArgumentCount ([int]$fixture.argumentCount)
        } catch {
            $reportPermalinkEvidenceCaught++
        }
    }
    if ($reportPermalinkEvidenceCaught -ne $reportPermalinkEvidenceNegatives.Count) {
        throw 'Report-permalink evidence negative fixtures did not fail closed.'
    }

    $proxyBootstrapWrapper = @"
if ([int]`$dexProxyBootstrapFlowFixtureResult.expectedFixtureCount -ne $ReviewedProxyBootstrapFixtureCount) {}
if (@(`$dexProxyBootstrapFlowFixtureResult.fixtures).Count -ne $ReviewedProxyBootstrapFixtureCount) {}
if ([int]`$dexProxyBootstrapFlowFixtureResult.inspectorArgumentCount -ne $ReviewedProxyBootstrapInspectorArgumentCount) {}
"@
    $proxyBootstrapHarness = @"
if ([int]`$expectedFixtureCount -ne $ReviewedProxyBootstrapFixtureCount) {}
if (`$results.Count -ne $ReviewedProxyBootstrapFixtureCount) {}
if ([int]`$inspectorArgumentCount -ne $ReviewedProxyBootstrapInspectorArgumentCount) {}
"@
    $proxyBootstrapWrapperAst = ConvertTo-ThreadsModReleaseToolAst `
        -Text $proxyBootstrapWrapper -Label 'positive proxy-bootstrap evidence wrapper fixture'
    $proxyBootstrapHarnessAst = ConvertTo-ThreadsModReleaseToolAst `
        -Text $proxyBootstrapHarness -Label 'positive proxy-bootstrap evidence harness fixture'
    $null = Assert-ThreadsModProxyBootstrapEvidenceContract `
        -ReleaseWrapperAst $proxyBootstrapWrapperAst `
        -FixtureHarnessAst $proxyBootstrapHarnessAst `
        -ReviewedFixtureCount $ReviewedProxyBootstrapFixtureCount `
        -ReviewedInspectorArgumentCount $ReviewedProxyBootstrapInspectorArgumentCount
    $proxyBootstrapEvidenceNegatives = @(
        [pscustomobject]@{
            id = 'proxy-bootstrap-divergent-fixture-count'
            wrapper = $proxyBootstrapWrapper.Replace(
                "expectedFixtureCount -ne $ReviewedProxyBootstrapFixtureCount",
                "expectedFixtureCount -ne $($ReviewedProxyBootstrapFixtureCount + 1)")
            harness = $proxyBootstrapHarness
            fixtureCount = $ReviewedProxyBootstrapFixtureCount
            argumentCount = $ReviewedProxyBootstrapInspectorArgumentCount
        },
        [pscustomobject]@{
            id = 'proxy-bootstrap-nonliteral-fixture-count'
            wrapper = $proxyBootstrapWrapper
            harness = $proxyBootstrapHarness.Replace(
                "expectedFixtureCount -ne $ReviewedProxyBootstrapFixtureCount",
                'expectedFixtureCount -ne $reviewed')
            fixtureCount = $ReviewedProxyBootstrapFixtureCount
            argumentCount = $ReviewedProxyBootstrapInspectorArgumentCount
        },
        [pscustomobject]@{
            id = 'proxy-bootstrap-divergent-inspector-count'
            wrapper = $proxyBootstrapWrapper.Replace(
                "inspectorArgumentCount -ne $ReviewedProxyBootstrapInspectorArgumentCount",
                "inspectorArgumentCount -ne $($ReviewedProxyBootstrapInspectorArgumentCount + 1)")
            harness = $proxyBootstrapHarness
            fixtureCount = $ReviewedProxyBootstrapFixtureCount
            argumentCount = $ReviewedProxyBootstrapInspectorArgumentCount
        },
        [pscustomobject]@{
            id = 'proxy-bootstrap-resolution-fixture-drift'
            wrapper = $proxyBootstrapWrapper
            harness = $proxyBootstrapHarness
            fixtureCount = $ReviewedProxyBootstrapFixtureCount + 1
            argumentCount = $ReviewedProxyBootstrapInspectorArgumentCount
        },
        [pscustomobject]@{
            id = 'proxy-bootstrap-resolution-argument-drift'
            wrapper = $proxyBootstrapWrapper
            harness = $proxyBootstrapHarness
            fixtureCount = $ReviewedProxyBootstrapFixtureCount
            argumentCount = $ReviewedProxyBootstrapInspectorArgumentCount + 1
        },
        [pscustomobject]@{
            id = 'proxy-bootstrap-duplicate-observed-count'
            wrapper = $proxyBootstrapWrapper +
                "if (@(`$dexProxyBootstrapFlowFixtureResult.fixtures).Count -ne $ReviewedProxyBootstrapFixtureCount) {}`n"
            harness = $proxyBootstrapHarness
            fixtureCount = $ReviewedProxyBootstrapFixtureCount
            argumentCount = $ReviewedProxyBootstrapInspectorArgumentCount
        }
    )
    $proxyBootstrapEvidenceCaught = 0
    $unexpectedProxyBootstrapEvidencePasses = @()
    foreach ($fixture in $proxyBootstrapEvidenceNegatives) {
        try {
            $negativeWrapperAst = ConvertTo-ThreadsModReleaseToolAst `
                -Text ([string]$fixture.wrapper) -Label ([string]$fixture.id)
            $negativeHarnessAst = ConvertTo-ThreadsModReleaseToolAst `
                -Text ([string]$fixture.harness) -Label ([string]$fixture.id)
            $null = Assert-ThreadsModProxyBootstrapEvidenceContract `
                -ReleaseWrapperAst $negativeWrapperAst `
                -FixtureHarnessAst $negativeHarnessAst `
                -ReviewedFixtureCount ([int]$fixture.fixtureCount) `
                -ReviewedInspectorArgumentCount ([int]$fixture.argumentCount)
            $unexpectedProxyBootstrapEvidencePasses += [string]$fixture.id
        } catch {
            $proxyBootstrapEvidenceCaught++
        }
    }
    if ($proxyBootstrapEvidenceCaught -ne $proxyBootstrapEvidenceNegatives.Count) {
        throw "Proxy-bootstrap evidence negative fixtures did not fail closed: $($unexpectedProxyBootstrapEvidencePasses -join ', ')."
    }

    $positiveInspectorGuard = @"
public static void main(String[] args) {
    if (args.length != $ReviewedInspectorArgumentCount) {
        return;
    }
}
"@
    $null = Assert-ThreadsModDexBridgeInspectorArgumentTextContract `
        -Text $positiveInspectorGuard -ReviewedArgumentCount $ReviewedInspectorArgumentCount `
        -Label 'positive inspector argument fixture'
    $staleInspectorArgumentCount = if ($ReviewedInspectorArgumentCount -eq 25) { 24 } else { 25 }
    $inspectorArgumentNegatives = @(
        [pscustomobject]@{ id='stale-inspector-argument-count'; text=$positiveInspectorGuard.Replace("args.length != $ReviewedInspectorArgumentCount", "args.length != $staleInspectorArgumentCount") },
        [pscustomobject]@{ id='nonliteral-inspector-argument-count'; text=$positiveInspectorGuard.Replace("args.length != $ReviewedInspectorArgumentCount", 'args.length != EXPECTED_ARGUMENTS') },
        [pscustomobject]@{ id='missing-inspector-argument-count'; text='public static void main(String[] args) { return; }' },
        [pscustomobject]@{ id='duplicate-inspector-argument-count'; text=$positiveInspectorGuard + $positiveInspectorGuard }
    )
    $inspectorArgumentCaught = 0
    $unexpectedInspectorArgumentPasses = @()
    foreach ($fixture in $inspectorArgumentNegatives) {
        try {
            $null = Assert-ThreadsModDexBridgeInspectorArgumentTextContract `
                -Text ([string]$fixture.text) `
                -ReviewedArgumentCount $ReviewedInspectorArgumentCount `
                -Label ([string]$fixture.id)
            $unexpectedInspectorArgumentPasses += [string]$fixture.id
        } catch {
            $inspectorArgumentCaught++
        }
    }
    if ($inspectorArgumentCaught -ne $inspectorArgumentNegatives.Count) {
        throw "Inspector argument-count negative fixtures did not fail closed: $($unexpectedInspectorArgumentPasses -join ', ')."
    }
    $positiveReportPermalinkInspectorGuard = @"
public static void main(String[] args) {
    if (args.length != $ReviewedReportPermalinkInspectorArgumentCount) {
        return;
    }
}
"@
    $null = Assert-ThreadsModDexBridgeInspectorArgumentTextContract `
        -Text $positiveReportPermalinkInspectorGuard `
        -ReviewedArgumentCount $ReviewedReportPermalinkInspectorArgumentCount `
        -Label 'positive report-permalink inspector argument fixture'
    $staleReportPermalinkArgumentCount = $ReviewedReportPermalinkInspectorArgumentCount + 1
    $reportPermalinkInspectorArgumentNegatives = @(
        $positiveReportPermalinkInspectorGuard.Replace(
            "args.length != $ReviewedReportPermalinkInspectorArgumentCount",
            "args.length != $staleReportPermalinkArgumentCount"),
        $positiveReportPermalinkInspectorGuard.Replace(
            "args.length != $ReviewedReportPermalinkInspectorArgumentCount",
            'args.length != EXPECTED_ARGUMENTS'),
        'public static void main(String[] args) { return; }',
        [string]::Concat(
            $positiveReportPermalinkInspectorGuard,
            $positiveReportPermalinkInspectorGuard)
    )
    $reportPermalinkInspectorArgumentCaught = 0
    foreach ($fixtureText in $reportPermalinkInspectorArgumentNegatives) {
        try {
            $null = Assert-ThreadsModDexBridgeInspectorArgumentTextContract `
                -Text ([string]$fixtureText) `
                -ReviewedArgumentCount $ReviewedReportPermalinkInspectorArgumentCount `
                -Label 'negative report-permalink inspector argument fixture'
        } catch {
            $reportPermalinkInspectorArgumentCaught++
        }
    }
    if ($reportPermalinkInspectorArgumentCaught `
            -ne $reportPermalinkInspectorArgumentNegatives.Count) {
        throw 'Report-permalink inspector argument negative fixtures did not fail closed.'
    }

    $reportPermalinkBindingWrapper = @'
$reportPermalinkLines = @(Invoke-Captured -Command $Java -Arguments @(
    '-cp', $dexLiteralClasspath, 'DexReportPermalinkFlowInspector', $apkFull,
    [string]$reportPermalinkContract.factoryMethodReference,
    [string]$reportPermalinkContract.resolvedMediaGetterReference,
    [string]$resolution.reporting.symbols.mediaBackingField,
    [string]$resolution.reporting.symbols.mediaPermalinkMethod,
    [string]$resolution.reporting.symbols.mediaCaptionMethod,
    [string]$reportPermalinkContract.requestConstructorReference,
    [string]$reportPermalinkContract.permalinkSanitizerMethodReference,
    [string]$reportPermalinkContract.requestPermalinkFieldReference,
    [string]$reportPermalinkContract.requestNewQueueValidityMethodReference,
    [string]$reportPermalinkContract.requestBaseValidityMethodReference,
    [string]$reportPermalinkContract.requestPermalinkGetterReference,
    [string]$reportPermalinkContract.payloadToJsonMethodReference,
    [string]$reportPermalinkContract.payloadRequestFieldReference,
    [string]$reportPermalinkContract.jsonPutMethodReference,
    [string]$reportPermalinkContract.jsonArrayPutMethodReference,
    [string]$reportPermalinkContract.stringLengthMethodReference,
    [string]$reportPermalinkContract.controllerQueueMethodReference,
    [string]$reportPermalinkContract.clientQueueMethodReference,
    [string]$reportPermalinkContract.threadStartMethodReference,
    [string]$reportPermalinkContract.jsonArrayConstructorMethodReference,
    [string]$resolution.reporting.symbols.mediaCodeMethod,
    [string]$resolution.reporting.symbols.captionTextMethod,
    [string]$reportPermalinkContract.permalinkResolverMethodReference,
    [string]$reportPermalinkContract.excerptResolverMethodReference,
    [string]$reportPermalinkContract.rowLabelGetterReference,
    [string]$reportPermalinkContract.inlineRowRenderMethodReference,
    [string]$reportPermalinkContract.currentViewerMethodReference,
    [string]$resolution.inlineControls.symbols.ufiButtonMethod,
    [string]$resolution.inlineControls.symbols.visibilityModifierMethod,
    [string]$resolution.inlineControls.symbols.testTagMethod,
    [string]$resolution.inlineControls.symbols.modifierComposedMethod,
    [string]$reportPermalinkContract.ufiButtonDefaultMask))
'@
    $reportPermalinkBindingHarness = @'
$commonArguments = @(
    [string]$contract.factoryMethodReference,
    [string]$contract.resolvedMediaGetterReference,
    [string]$resolution.reporting.symbols.mediaBackingField,
    [string]$resolution.reporting.symbols.mediaPermalinkMethod,
    [string]$resolution.reporting.symbols.mediaCaptionMethod,
    [string]$contract.requestConstructorReference,
    [string]$contract.permalinkSanitizerMethodReference,
    [string]$contract.requestPermalinkFieldReference,
    [string]$contract.requestNewQueueValidityMethodReference,
    [string]$contract.requestBaseValidityMethodReference,
    [string]$contract.requestPermalinkGetterReference,
    [string]$contract.payloadToJsonMethodReference,
    [string]$contract.payloadRequestFieldReference,
    [string]$contract.jsonPutMethodReference,
    [string]$contract.jsonArrayPutMethodReference,
    [string]$contract.stringLengthMethodReference,
    [string]$contract.controllerQueueMethodReference,
    [string]$contract.clientQueueMethodReference,
    [string]$contract.threadStartMethodReference,
    [string]$contract.jsonArrayConstructorMethodReference,
    [string]$resolution.reporting.symbols.mediaCodeMethod,
    [string]$resolution.reporting.symbols.captionTextMethod,
    [string]$contract.permalinkResolverMethodReference,
    [string]$contract.excerptResolverMethodReference,
    [string]$contract.rowLabelGetterReference,
    [string]$contract.inlineRowRenderMethodReference,
    [string]$contract.currentViewerMethodReference,
    [string]$resolution.inlineControls.symbols.ufiButtonMethod,
    [string]$resolution.inlineControls.symbols.visibilityModifierMethod,
    [string]$resolution.inlineControls.symbols.testTagMethod,
    [string]$resolution.inlineControls.symbols.modifierComposedMethod,
    [string]$contract.ufiButtonDefaultMask)
'@
    $reportPermalinkBindingWrapperAst = ConvertTo-ThreadsModReleaseToolAst `
        -Text $reportPermalinkBindingWrapper `
        -Label 'positive report-permalink binding wrapper fixture'
    $reportPermalinkBindingHarnessAst = ConvertTo-ThreadsModReleaseToolAst `
        -Text $reportPermalinkBindingHarness `
        -Label 'positive report-permalink binding harness fixture'
    $null = Assert-ThreadsModReportPermalinkInspectorBindingContract `
        -ReleaseWrapperAst $reportPermalinkBindingWrapperAst `
        -FixtureHarnessAst $reportPermalinkBindingHarnessAst `
        -ReviewedArgumentCount $ReviewedReportPermalinkInspectorArgumentCount

    $reportPermalinkBindingOrderDrift = $reportPermalinkBindingWrapper.Replace(
        '$resolution.reporting.symbols.mediaCodeMethod',
        '$resolution.reporting.symbols.__mediaCodeMethod')
    $reportPermalinkBindingOrderDrift = $reportPermalinkBindingOrderDrift.Replace(
        '$resolution.reporting.symbols.captionTextMethod',
        '$resolution.reporting.symbols.mediaCodeMethod')
    $reportPermalinkBindingOrderDrift = $reportPermalinkBindingOrderDrift.Replace(
        '$resolution.reporting.symbols.__mediaCodeMethod',
        '$resolution.reporting.symbols.captionTextMethod')
    $reportPermalinkBindingHarnessDrift = $reportPermalinkBindingHarness.Replace(
        '$contract.permalinkResolverMethodReference',
        '$contract.__permalinkResolverMethodReference')
    $reportPermalinkBindingHarnessDrift = $reportPermalinkBindingHarnessDrift.Replace(
        '$contract.excerptResolverMethodReference',
        '$contract.permalinkResolverMethodReference')
    $reportPermalinkBindingHarnessDrift = $reportPermalinkBindingHarnessDrift.Replace(
        '$contract.__permalinkResolverMethodReference',
        '$contract.excerptResolverMethodReference')
    $reportPermalinkBindingNegatives = @(
        [pscustomobject]@{
            id = 'report-permalink-binding-order'
            wrapper = $reportPermalinkBindingOrderDrift
            harness = $reportPermalinkBindingHarness
        },
        [pscustomobject]@{
            id = 'report-permalink-binding-divergence'
            wrapper = $reportPermalinkBindingWrapper
            harness = $reportPermalinkBindingHarnessDrift
        },
        [pscustomobject]@{
            id = 'report-permalink-binding-substitution'
            wrapper = $reportPermalinkBindingWrapper.Replace(
                '[string]$resolution.reporting.symbols.mediaCodeMethod',
                '[string]$resolution.reporting.symbols.mediaCaptionMethod')
            harness = $reportPermalinkBindingHarness
        },
        [pscustomobject]@{
            id = 'report-permalink-binding-missing'
            wrapper = $reportPermalinkBindingWrapper.Replace(
                '[string]$reportPermalinkContract.ufiButtonDefaultMask',
                "[string]''")
            harness = $reportPermalinkBindingHarness
        },
        [pscustomobject]@{
            id = 'report-permalink-binding-extra'
            wrapper = $reportPermalinkBindingWrapper.Replace(
                '[string]$reportPermalinkContract.ufiButtonDefaultMask))',
                '[string]$reportPermalinkContract.ufiButtonDefaultMask, [string]$reportPermalinkContract.factoryMethodReference))')
            harness = $reportPermalinkBindingHarness
        },
        [pscustomobject]@{
            id = 'report-permalink-binding-misplaced'
            wrapper = $reportPermalinkBindingWrapper.Replace(
                '[string]$reportPermalinkContract.ufiButtonDefaultMask))',
                '[string]$reportPermalinkContract.ufiButtonDefaultMask) + @([string]$reportPermalinkContract.factoryMethodReference))')
            harness = $reportPermalinkBindingHarness
        },
        [pscustomobject]@{
            id = 'report-permalink-inline-binding-order'
            wrapper = $reportPermalinkBindingWrapper.Replace(
                '[string]$resolution.inlineControls.symbols.visibilityModifierMethod',
                '[string]$resolution.inlineControls.symbols.__visibilityModifierMethod').Replace(
                '[string]$resolution.inlineControls.symbols.testTagMethod',
                '[string]$resolution.inlineControls.symbols.visibilityModifierMethod').Replace(
                '[string]$resolution.inlineControls.symbols.__visibilityModifierMethod',
                '[string]$resolution.inlineControls.symbols.testTagMethod')
            harness = $reportPermalinkBindingHarness
        },
        [pscustomobject]@{
            id = 'report-permalink-inline-binding-substitution'
            wrapper = $reportPermalinkBindingWrapper.Replace(
                '[string]$resolution.inlineControls.symbols.ufiButtonMethod',
                '[string]$resolution.inlineControls.symbols.testTagMethod')
            harness = $reportPermalinkBindingHarness
        }
    )
    $reportPermalinkBindingCaught = 0
    $unexpectedReportPermalinkBindingPasses = @()
    foreach ($fixture in $reportPermalinkBindingNegatives) {
        try {
            $negativeWrapperAst = ConvertTo-ThreadsModReleaseToolAst `
                -Text ([string]$fixture.wrapper) -Label ([string]$fixture.id)
            $negativeHarnessAst = ConvertTo-ThreadsModReleaseToolAst `
                -Text ([string]$fixture.harness) -Label ([string]$fixture.id)
            $null = Assert-ThreadsModReportPermalinkInspectorBindingContract `
                -ReleaseWrapperAst $negativeWrapperAst `
                -FixtureHarnessAst $negativeHarnessAst `
                -ReviewedArgumentCount $ReviewedReportPermalinkInspectorArgumentCount
            $unexpectedReportPermalinkBindingPasses += [string]$fixture.id
        } catch {
            $reportPermalinkBindingCaught++
        }
    }
    if ($reportPermalinkBindingCaught -ne $reportPermalinkBindingNegatives.Count) {
        throw "Report-permalink binding negative fixtures did not fail closed: $($unexpectedReportPermalinkBindingPasses -join ', ')."
    }

    $positiveProxyBootstrapInspectorGuard = @"
public static void main(String[] args) {
    if (args.length != $ReviewedProxyBootstrapInspectorArgumentCount) {
        return;
    }
}
"@
    $null = Assert-ThreadsModDexBridgeInspectorArgumentTextContract `
        -Text $positiveProxyBootstrapInspectorGuard `
        -ReviewedArgumentCount $ReviewedProxyBootstrapInspectorArgumentCount `
        -Label 'positive proxy-bootstrap inspector argument fixture'
    $staleProxyBootstrapArgumentCount = $ReviewedProxyBootstrapInspectorArgumentCount + 1
    $proxyBootstrapInspectorArgumentNegatives = @(
        $positiveProxyBootstrapInspectorGuard.Replace(
            "args.length != $ReviewedProxyBootstrapInspectorArgumentCount",
            "args.length != $staleProxyBootstrapArgumentCount"),
        $positiveProxyBootstrapInspectorGuard.Replace(
            "args.length != $ReviewedProxyBootstrapInspectorArgumentCount",
            'args.length != EXPECTED_ARGUMENTS'),
        'public static void main(String[] args) { return; }',
        [string]::Concat(
            $positiveProxyBootstrapInspectorGuard,
            $positiveProxyBootstrapInspectorGuard)
    )
    $proxyBootstrapInspectorArgumentCaught = 0
    foreach ($fixtureText in $proxyBootstrapInspectorArgumentNegatives) {
        try {
            $null = Assert-ThreadsModDexBridgeInspectorArgumentTextContract `
                -Text ([string]$fixtureText) `
                -ReviewedArgumentCount $ReviewedProxyBootstrapInspectorArgumentCount `
                -Label 'negative proxy-bootstrap inspector argument fixture'
        } catch {
            $proxyBootstrapInspectorArgumentCaught++
        }
    }
    if ($proxyBootstrapInspectorArgumentCaught `
            -ne $proxyBootstrapInspectorArgumentNegatives.Count) {
        throw 'Proxy-bootstrap inspector argument negative fixtures did not fail closed.'
    }

    $proxyBootstrapBindingWrapper = @'
$proxyBootstrapLines = @(Invoke-Captured -Command $Java -Arguments @(
    '-cp', $dexLiteralClasspath, 'DexProxyBootstrapFlowInspector', $apkFull,
    [string]$proxyBootstrapContract.expectedDexName,
    [string]$proxyBootstrapContract.ownerClassDescriptor,
    [string]$proxyBootstrapContract.ownerMethodName,
    [string]$proxyBootstrapContract.ownerMethodDescriptor,
    [string]$proxyBootstrapContract.superClassDescriptor,
    [string]$proxyBootstrapContract.superMethodName,
    [string]$proxyBootstrapContract.superMethodDescriptor,
    [string]$proxyBootstrapContract.bootstrapClassDescriptor,
    [string]$proxyBootstrapContract.bootstrapMethodName,
    [string]$proxyBootstrapContract.bootstrapMethodDescriptor))
'@
    $proxyBootstrapBindingHarness = @'
$commonArguments = @(
    [string]$contract.expectedDexName,
    [string]$contract.ownerClassDescriptor,
    [string]$contract.ownerMethodName,
    [string]$contract.ownerMethodDescriptor,
    [string]$contract.superClassDescriptor,
    [string]$contract.superMethodName,
    [string]$contract.superMethodDescriptor,
    [string]$contract.bootstrapClassDescriptor,
    [string]$contract.bootstrapMethodName,
    [string]$contract.bootstrapMethodDescriptor)
'@
    $proxyBootstrapBindingWrapperAst = ConvertTo-ThreadsModReleaseToolAst `
        -Text $proxyBootstrapBindingWrapper `
        -Label 'positive proxy-bootstrap binding wrapper fixture'
    $proxyBootstrapBindingHarnessAst = ConvertTo-ThreadsModReleaseToolAst `
        -Text $proxyBootstrapBindingHarness `
        -Label 'positive proxy-bootstrap binding harness fixture'
    $null = Assert-ThreadsModProxyBootstrapInspectorBindingContract `
        -ReleaseWrapperAst $proxyBootstrapBindingWrapperAst `
        -FixtureHarnessAst $proxyBootstrapBindingHarnessAst `
        -ReviewedArgumentCount $ReviewedProxyBootstrapInspectorArgumentCount

    $proxyBootstrapBindingOrderDrift = $proxyBootstrapBindingWrapper.Replace(
        '$proxyBootstrapContract.expectedDexName',
        '$proxyBootstrapContract.__expectedDexName')
    $proxyBootstrapBindingOrderDrift = $proxyBootstrapBindingOrderDrift.Replace(
        '$proxyBootstrapContract.ownerClassDescriptor',
        '$proxyBootstrapContract.expectedDexName')
    $proxyBootstrapBindingOrderDrift = $proxyBootstrapBindingOrderDrift.Replace(
        '$proxyBootstrapContract.__expectedDexName',
        '$proxyBootstrapContract.ownerClassDescriptor')
    $proxyBootstrapBindingNegatives = @(
        [pscustomobject]@{
            id = 'proxy-bootstrap-binding-order'
            wrapper = $proxyBootstrapBindingOrderDrift
            harness = $proxyBootstrapBindingHarness
        },
        [pscustomobject]@{
            id = 'proxy-bootstrap-binding-missing'
            wrapper = $proxyBootstrapBindingWrapper.Replace(
                '[string]$proxyBootstrapContract.expectedDexName', "[string]''")
            harness = $proxyBootstrapBindingHarness
        },
        [pscustomobject]@{
            id = 'proxy-bootstrap-binding-duplicate'
            wrapper = $proxyBootstrapBindingWrapper.Replace(
                '[string]$proxyBootstrapContract.bootstrapMethodDescriptor)',
                '[string]$proxyBootstrapContract.bootstrapMethodDescriptor, [string]$proxyBootstrapContract.expectedDexName)')
            harness = $proxyBootstrapBindingHarness
        },
        [pscustomobject]@{
            id = 'proxy-bootstrap-binding-extra-untyped'
            wrapper = $proxyBootstrapBindingWrapper.Replace(
                '[string]$proxyBootstrapContract.bootstrapMethodDescriptor)',
                '[string]$proxyBootstrapContract.bootstrapMethodDescriptor, $unreviewedExtra)')
            harness = $proxyBootstrapBindingHarness
        },
        [pscustomobject]@{
            id = 'proxy-bootstrap-binding-wrong-variable'
            wrapper = $proxyBootstrapBindingWrapper
            harness = $proxyBootstrapBindingHarness.Replace(
                '[string]$contract.expectedDexName', '[string]$unreviewed.expectedDexName')
        }
    )
    $proxyBootstrapBindingCaught = 0
    $unexpectedProxyBootstrapBindingPasses = @()
    foreach ($fixture in $proxyBootstrapBindingNegatives) {
        try {
            $negativeWrapperAst = ConvertTo-ThreadsModReleaseToolAst `
                -Text ([string]$fixture.wrapper) -Label ([string]$fixture.id)
            $negativeHarnessAst = ConvertTo-ThreadsModReleaseToolAst `
                -Text ([string]$fixture.harness) -Label ([string]$fixture.id)
            $null = Assert-ThreadsModProxyBootstrapInspectorBindingContract `
                -ReleaseWrapperAst $negativeWrapperAst `
                -FixtureHarnessAst $negativeHarnessAst `
                -ReviewedArgumentCount $ReviewedProxyBootstrapInspectorArgumentCount
            $unexpectedProxyBootstrapBindingPasses += [string]$fixture.id
        } catch {
            $proxyBootstrapBindingCaught++
        }
    }
    if ($proxyBootstrapBindingCaught -ne $proxyBootstrapBindingNegatives.Count) {
        throw "Proxy-bootstrap binding negative fixtures did not fail closed: $($unexpectedProxyBootstrapBindingPasses -join ', ')."
    }

    return [pscustomobject]@{
        status = 'passed'
        invocationNegativeFixtures = $caught
        evidenceNegativeFixtures = $evidenceCaught
        bridgeInspectorBindingNegativeFixtures = $bindingCaught
        inspectorArgumentNegativeFixtures = $inspectorArgumentCaught
        reportPermalinkEvidenceNegativeFixtures = $reportPermalinkEvidenceCaught
        reportPermalinkInspectorArgumentNegativeFixtures = `
            $reportPermalinkInspectorArgumentCaught
        reportPermalinkInspectorBindingNegativeFixtures = $reportPermalinkBindingCaught
        proxyBootstrapEvidenceNegativeFixtures = $proxyBootstrapEvidenceCaught
        proxyBootstrapInspectorArgumentNegativeFixtures = `
            $proxyBootstrapInspectorArgumentCaught
        proxyBootstrapInspectorBindingNegativeFixtures = $proxyBootstrapBindingCaught
    }
}

Export-ModuleMember -Function @(
    'Get-ThreadsModReleaseToolAst',
    'Assert-ThreadsModReleaseEvidenceContract',
    'Assert-ThreadsModReportPermalinkEvidenceContract',
    'Assert-ThreadsModProxyBootstrapEvidenceContract',
    'Assert-ThreadsModDexBridgeInspectorArgumentContract',
    'Assert-ThreadsModDexBridgeInspectorBindingContract',
    'Assert-ThreadsModReportPermalinkInspectorArgumentContract',
    'Assert-ThreadsModReportPermalinkInspectorBindingContract',
    'Assert-ThreadsModProxyBootstrapInspectorArgumentContract',
    'Assert-ThreadsModProxyBootstrapInspectorBindingContract',
    'Test-ThreadsModReleaseToolInvocationContracts',
    'Test-ThreadsModReleaseToolContractNegativeFixtures')
