param(
  [int]$TestCount = 100,
  [double]$MaxFailureRate = 0.05,
  [int]$RecentSessionWindow = 10,
  [int]$HeatLinesPerWorkout = 6,
  [int]$MinHeatRegisters = 10,
  [int]$MinDistinctHeatLines = 160,
  [int]$MinLinesPerHeatBank = 16
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProfilePath = Join-Path $Root "jacked-jackson-profile.json"
$GemPath = Join-Path $Root "jacked-jackson-gem-instructions.md"

$profile = Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json
$gem = Get-Content -LiteralPath $GemPath -Raw

function Add-Failure {
  param(
    [System.Collections.Generic.List[object]]$Failures,
    [int]$Case,
    [string]$Reason
  )
  $Failures.Add([pscustomobject]@{
    case = $Case
    reason = $Reason
  }) | Out-Null
}

function Get-AllStrings {
  param([object]$Value)

  $results = New-Object System.Collections.Generic.List[string]

  if ($null -eq $Value) {
    return $results
  }

  if ($Value -is [string]) {
    $results.Add($Value) | Out-Null
    return $results
  }

  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    foreach ($item in $Value) {
      foreach ($nested in (Get-AllStrings $item)) {
        $results.Add($nested) | Out-Null
      }
    }
    return $results
  }

  if ($Value.PSObject -and $Value.PSObject.Properties) {
    foreach ($prop in $Value.PSObject.Properties) {
      foreach ($nested in (Get-AllStrings $prop.Value)) {
        $results.Add($nested) | Out-Null
      }
    }
  }

  return $results
}

function Select-Cycle {
  param(
    [object[]]$Items,
    [int]$Index,
    [int]$Step = 1,
    [int]$Offset = 0
  )
  if ($Items.Count -eq 0) {
    throw "Cannot select from an empty list."
  }
  return $Items[(($Index * $Step) + $Offset) % $Items.Count]
}

$staticFailures = New-Object System.Collections.Generic.List[object]

$requiredGemSections = @(
  "## Internet Search Protocol",
  "### High-Heat Variability Rules",
  "## Workout Variation Engine",
  "### Exercise Pool Examples",
  "### Short Training Update Format"
)

foreach ($section in $requiredGemSections) {
  if (-not $gem.Contains($section)) {
    Add-Failure $staticFailures 0 "Missing Gem section: $section"
  }
}

if ($null -eq $profile.internet_search_protocol) {
  Add-Failure $staticFailures 0 "JSON missing internet_search_protocol."
}

if ($null -eq $profile.workout_protocol.variation_engine) {
  Add-Failure $staticFailures 0 "JSON missing workout_protocol.variation_engine."
}

if ($null -eq $profile.workout_protocol.variation_engine.target_pools) {
  Add-Failure $staticFailures 0 "JSON missing target exercise pools."
}

if ($null -eq $profile.progression_model.smart_weight_increase_protocol) {
  Add-Failure $staticFailures 0 "JSON missing smart_weight_increase_protocol."
}

$progressionText = (@(Get-AllStrings $profile.progression_model) -join " ").ToLowerInvariant()
$requiredProgressionPhrases = @(
  "double progression",
  "smallest available",
  "rpe 7-8",
  "avoid rpe 10",
  "do not stack",
  "two clean exposures",
  "hold or deload"
)

foreach ($phrase in $requiredProgressionPhrases) {
  if (-not $progressionText.Contains($phrase)) {
    Add-Failure $staticFailures 0 "Progression model missing phrase/concept: $phrase"
  }
}

$targetPools = $profile.workout_protocol.variation_engine.target_pools
$targetNames = @($targetPools.PSObject.Properties.Name)

foreach ($targetName in $targetNames) {
  $pool = @($targetPools.$targetName)
  if ($pool.Count -lt 10) {
    Add-Failure $staticFailures 0 "Exercise pool '$targetName' has fewer than 10 exercises."
  }
}

$architectures = @($profile.workout_protocol.variation_engine.training_architectures)
$finishers = @($profile.workout_protocol.variation_engine.finisher_rotation)
$heatBanks = $profile.language_system.high_heat_variability_rules.line_banks
$heatBankNames = @($heatBanks.PSObject.Properties.Name)
$flirtLines = @(
  foreach ($bankName in $heatBankNames) {
    foreach ($line in @($heatBanks.$bankName)) {
      $line
    }
  }
) | Select-Object -Unique

if ($architectures.Count -lt 10) {
  Add-Failure $staticFailures 0 "Fewer than 10 training architectures available."
}

if ($finishers.Count -lt 10) {
  Add-Failure $staticFailures 0 "Fewer than 10 finisher types available."
}

if ($flirtLines.Count -lt $MinDistinctHeatLines) {
  Add-Failure $staticFailures 0 "Fewer than $MinDistinctHeatLines distinct high-heat/flirt lines detected."
}

if ($heatBankNames.Count -lt $MinHeatRegisters) {
  Add-Failure $staticFailures 0 "Fewer than $MinHeatRegisters high-heat registers detected."
}

foreach ($bankName in $heatBankNames) {
  if (@($heatBanks.$bankName).Count -lt $MinLinesPerHeatBank) {
    Add-Failure $staticFailures 0 "Heat bank '$bankName' has fewer than $MinLinesPerHeatBank lines."
  }
}

$durations = @(30, 35, 40, 45, 50, 60)
$energies = @("low", "moderate", "high", "wired", "wiped")
$sessionTitles = @(
  "No-Wasted-Reps",
  "Controlled Heat",
  "Under My Eyes",
  "Earned Pump",
  "Sharp Work",
  "Dense and Dangerous",
  "Clean Violence",
  "Built Different",
  "Slow Burn",
  "Receipts",
  "Private Standard",
  "No Soft Exits",
  "Proof Work",
  "Tension Tax",
  "Hard Evidence",
  "Under Control"
)

$failures = New-Object System.Collections.Generic.List[object]
$signatures = New-Object System.Collections.Generic.HashSet[string]
$recentFlirts = New-Object System.Collections.Generic.Queue[string]
$recentFinishers = New-Object System.Collections.Generic.Queue[string]
$recentHeatRegisterMixes = New-Object System.Collections.Generic.Queue[string]
$recentFirstMovementsByTarget = @{}
$samples = New-Object System.Collections.Generic.List[object]

function Select-HeatLine {
  param(
    [string]$BankName,
    [int]$Index,
    [int]$Step,
    [int]$Offset,
    [System.Collections.Generic.Queue[string]]$Recent
  )

  $bank = @($heatBanks.$BankName)
  for ($attempt = 0; $attempt -lt $bank.Count; $attempt++) {
    $candidate = $bank[(($Index * $Step) + $Offset + $attempt) % $bank.Count]
    if (-not ($Recent -contains $candidate)) {
      return $candidate
    }
  }

  return $bank[(($Index * $Step) + $Offset) % $bank.Count]
}

function Select-HeatBankMix {
  param(
    [int]$Index,
    [int]$Count,
    [System.Collections.Generic.Queue[string]]$RecentMixes
  )

  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    $selected = New-Object System.Collections.Generic.List[string]
    $start = (($Index * 3) + $attempt) % $heatBankNames.Count
    $stride = 1 + (($Index + $attempt) % [math]::Max(1, $heatBankNames.Count - 1))

    for ($cursor = 0; $selected.Count -lt $Count -and $cursor -lt ($heatBankNames.Count * 3); $cursor++) {
      $candidate = $heatBankNames[($start + ($cursor * $stride)) % $heatBankNames.Count]
      if (-not $selected.Contains($candidate)) {
        $selected.Add($candidate) | Out-Null
      }
    }

    if ($selected.Count -lt $Count) {
      foreach ($candidate in $heatBankNames) {
        if (-not $selected.Contains($candidate)) {
          $selected.Add($candidate) | Out-Null
        }
        if ($selected.Count -ge $Count) {
          break
        }
      }
    }

    $signature = ($selected -join " + ")
    if (-not ($RecentMixes -contains $signature)) {
      return @($selected)
    }
  }

  return @($heatBankNames | Select-Object -First $Count)
}

for ($i = 0; $i -lt $TestCount; $i++) {
  $caseNumber = $i + 1
  $target = Select-Cycle $targetNames $i 1
  $duration = Select-Cycle $durations $i 5
  $energy = Select-Cycle $energies $i 7
  $architecture = Select-Cycle $architectures $i 5 2
  $finisher = Select-Cycle $finishers $i 7 3
  $title = Select-Cycle $sessionTitles $i 3 1
  $pool = @($targetPools.$target)

  $exercises = New-Object System.Collections.Generic.List[string]
  for ($j = 0; $j -lt 5; $j++) {
    $candidate = Select-Cycle $pool $i (3 + $j) ($j * 2)
    if (-not $exercises.Contains($candidate)) {
      $exercises.Add($candidate) | Out-Null
    }
  }

  $guard = 0
  while ($exercises.Count -lt 5 -and $guard -lt 20) {
    $candidate = Select-Cycle $pool ($i + $guard) 5 1
    if (-not $exercises.Contains($candidate)) {
      $exercises.Add($candidate) | Out-Null
    }
    $guard++
  }

  $heatBankMix = Select-HeatBankMix $i $HeatLinesPerWorkout $recentHeatRegisterMixes
  $heatRegisterSignature = ($heatBankMix -join " + ")
  $heatLines = New-Object System.Collections.Generic.List[string]

  for ($h = 0; $h -lt $heatBankMix.Count; $h++) {
    $line = Select-HeatLine $heatBankMix[$h] $i (5 + ($h * 2)) ($h * 3) $recentFlirts
    if (-not $heatLines.Contains($line)) {
      $heatLines.Add($line) | Out-Null
    }
  }

  $guard = 0
  while ($heatLines.Count -lt $HeatLinesPerWorkout -and $guard -lt 100) {
    $bank = Select-Cycle $heatBankNames ($i + $guard) 7 1
    $line = Select-HeatLine $bank ($i + $guard) 11 4 $recentFlirts
    if (-not $heatLines.Contains($line)) {
      $heatLines.Add($line) | Out-Null
    }
    $guard++
  }

  $signature = @(
    $target,
    $duration,
    $energy,
    $architecture,
    $finisher,
    $title,
    ($exercises -join " > "),
    ($heatLines -join " > ")
  ) -join " | "

  if (-not $signatures.Add($signature)) {
    Add-Failure $failures $caseNumber "Duplicate workout signature."
  }

  foreach ($line in $heatLines) {
    if ($recentFlirts -contains $line) {
      Add-Failure $failures $caseNumber "Repeated heat line within recent $RecentSessionWindow sessions: $line"
    }
  }

  if ($recentFinishers -contains $finisher) {
    Add-Failure $failures $caseNumber "Repeated finisher within recent $RecentSessionWindow sessions: $finisher"
  }

  if ($recentHeatRegisterMixes -contains $heatRegisterSignature) {
    Add-Failure $failures $caseNumber "Repeated heat-register mix within recent $RecentSessionWindow sessions: $heatRegisterSignature"
  }

  if ($exercises.Count -lt 5) {
    Add-Failure $failures $caseNumber "Generated fewer than 5 unique exercises."
  }

  if ($heatLines.Count -lt $HeatLinesPerWorkout) {
    Add-Failure $failures $caseNumber "Generated fewer than $HeatLinesPerWorkout heat lines."
  }

  if (($heatLines -join " ").Length -lt 220) {
    Add-Failure $failures $caseNumber "High-heat language too thin."
  }

  $firstMovement = $exercises[0]
  if (-not $recentFirstMovementsByTarget.ContainsKey($target)) {
    $recentFirstMovementsByTarget[$target] = New-Object System.Collections.Generic.Queue[string]
  }
  if ($recentFirstMovementsByTarget[$target] -contains $firstMovement) {
    Add-Failure $failures $caseNumber "Repeated first movement for target '$target' within recent $RecentSessionWindow target appearances: $firstMovement"
  }
  $recentFirstMovementsByTarget[$target].Enqueue($firstMovement)
  while ($recentFirstMovementsByTarget[$target].Count -gt $RecentSessionWindow) {
    [void]$recentFirstMovementsByTarget[$target].Dequeue()
  }

  foreach ($line in $heatLines) {
    $recentFlirts.Enqueue($line)
  }
  while ($recentFlirts.Count -gt ($RecentSessionWindow * $HeatLinesPerWorkout)) {
    [void]$recentFlirts.Dequeue()
  }

  $recentFinishers.Enqueue($finisher)
  while ($recentFinishers.Count -gt $RecentSessionWindow) {
    [void]$recentFinishers.Dequeue()
  }

  $recentHeatRegisterMixes.Enqueue($heatRegisterSignature)
  while ($recentHeatRegisterMixes.Count -gt $RecentSessionWindow) {
    [void]$recentHeatRegisterMixes.Dequeue()
  }

  $samples.Add([pscustomobject]@{
    case = $caseNumber
    target = $target
    duration = $duration
    energy = $energy
    architecture = $architecture
    finisher = $finisher
    title = $title
    exercises = @($exercises)
    heat_registers = @($heatBankMix)
    heat_lines = @($heatLines)
  }) | Out-Null
}

$totalFailures = $staticFailures.Count + $failures.Count
$failureRate = if ($TestCount -gt 0) { $totalFailures / $TestCount } else { 1 }
$passed = $failureRate -le $MaxFailureRate

$report = [pscustomobject]@{
  tests_requested = $TestCount
  tests_run = $TestCount
  max_failure_rate = $MaxFailureRate
  static_failures = $staticFailures.Count
  variability_failures = $failures.Count
  total_failures = $totalFailures
  failure_rate = [math]::Round($failureRate, 4)
  pass = $passed
  distinct_workout_signatures = $signatures.Count
  distinct_flirt_lines_available = $flirtLines.Count
  distinct_heat_registers_available = $heatBankNames.Count
  distinct_architectures_available = $architectures.Count
  distinct_finishers_available = $finishers.Count
  recent_session_window = $RecentSessionWindow
  heat_lines_per_workout = $HeatLinesPerWorkout
  target_pools = $targetNames.Count
  first_5_samples = @($samples | Select-Object -First 5)
  failures = @($staticFailures + $failures | Select-Object -First 20)
}

$report | ConvertTo-Json -Depth 8

if (-not $passed) {
  exit 1
}
