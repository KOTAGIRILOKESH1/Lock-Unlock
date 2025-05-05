param (
    [string[]]$ManagementGroups = @("SGmanagementtest", "managementtesing"),
    [string[]]$Subscriptions = @("3bc8f069-65c7-4d08-b8de-534c20e56c38", "95d6c462-6712-41f0-974a-956027bf3fc7"),
    [string[]]$ResourceGroups = @("linux-VM", "Windows-VM", "linux-testing"),
    [ValidateSet("lock", "unlock")]
    [string]$Mode = "unlock",
    [string]$ResourceTypeFilePath = "C:\Users\ktssk\Downloads\samplepoc\Resourcetype.txt"
)

Import-Module Az.Accounts -ErrorAction Stop
Import-Module Az.Resources -ErrorAction Stop

if (-not (Get-AzContext)) {
    Connect-AzAccount
}

# Build resource type map
$resourceTypeMap = @{}
Get-Content $ResourceTypeFilePath | ForEach-Object {
    $line = $_.Trim()
    if ($line -and $line.Contains(',')) {
        $parts = $line.Split(',')
        $friendly = $parts[0].Trim().ToLower()
        $actual = $parts[1].Trim()
        $resourceTypeMap[$friendly] = $actual
    }
}

if (-not $resourceTypeMap.Count) {
    Write-Error "❌ No valid resource types in file."
    exit 1
}

$mappedTypes = $resourceTypeMap.Values | Select-Object -Unique

foreach ($mgName in $ManagementGroups) {
    Write-Output "`n📦 Checking Management Group: $mgName"

    try {
        $mg = Get-AzManagementGroup -GroupName $mgName -ErrorAction Stop
    } catch {
        Write-Warning "⚠️ Management Group '$mgName' not found or access denied. Skipping."
        continue
    }

    try {
        $mgSubs = Get-AzManagementGroupSubscription -GroupName $mgName -ErrorAction Stop | ForEach-Object {
            $_.Id.Split("/")[-1]
        }
    } catch {
        Write-Warning "⚠️ Could not retrieve subscriptions for MG '$mgName'. Check permissions. Skipping."
        continue
    }

    # Your logic to loop over $Subscriptions and match them to $mgSubs goes here...
}


    foreach ($sub in $Subscriptions) {
        if ($mgSubs -notcontains $sub) {
            Write-Output "❌ Subscription $sub not in $mg. Skipping..."
            continue
        }

        Write-Output "✅ Processing Subscription: $sub under MG: $mg"
        try {
            Set-AzContext -SubscriptionId $sub -ErrorAction Stop | Out-Null
        } catch {
            Write-Warning "⚠️ Cannot set context to $sub. Skipping..."
            continue
        }

        foreach ($rg in $ResourceGroups) {
            try {
                $exists = Get-AzResourceGroup -Name $rg -ErrorAction Stop
            } catch {
                Write-Output "❌ Resource Group '$rg' not found in subscription $sub"
                continue
            }

            Write-Output "`n📁 Processing RG: $rg"

            foreach ($type in $mappedTypes) {
                $resources = Get-AzResource -ResourceGroupName $rg -ResourceType $type -ErrorAction SilentlyContinue
                foreach ($res in $resources) {
                    $resourceId = $res.ResourceId
                    $existingLocks = @(Get-AzResourceLock -Scope $resourceId -ErrorAction SilentlyContinue)

                    if ($Mode -eq "lock") {
                        $hasDeleteLock = $existingLocks | Where-Object { $_.LockLevel -eq "CanNotDelete" }
                        if ($hasDeleteLock) {
                            Write-Output "🔒 '$($res.Name)' already has delete lock. Skipping."
                        } else {
                            $lockName = "$($res.Name)-DeleteLock"
                            Write-Output "➕ Applying Delete Lock to: $($res.Name)"
                            New-AzResourceLock -LockName $lockName -Scope $resourceId -LockLevel CanNotDelete -Force
                        }
                    } elseif ($Mode -eq "unlock") {
                        foreach ($lock in $existingLocks) {
                            if ($lock.LockId) {
                                Write-Output "❌ Removing Lock (ID: $($lock.LockId), Name: $($lock.Name)) from $($res.Name)"
                                Remove-AzResourceLock -LockId $lock.LockId -Force
                            } else {
                                Write-Output "⚠️ Skipping lock with no LockId on $($res.Name)"
                            }
                        }
                    }

                }
            }
        }
    }

