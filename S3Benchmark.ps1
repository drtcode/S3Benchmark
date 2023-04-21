<#
.SYNOPSIS
Generates random data of a specific size and uploads it to an S3 bucket.
.DESCRIPTION
This script will benchmark performance from a given machine, where it is run from, to an S3 target.
After configuring the target environment, the test can perform the uploads directly from memory or can optionally be instructed to perform the uploads from a disk target.
By using the default in-memory data generation & upload, the disk is bypassed, thereby eliminating it as a potential bottleneck.

PREREQUISITES:
The AWS.Tools.S3 powershell module, published by AWS, is required to run this tool. You will have to install it manually before running.
    e.g. Install-Module AWS.Tools.S3

USAGE:
Load the module:
    . .\S3Benchmark.ps1
    Optionally, you can set the -Setup and/or -StartTest switches to immediately setup & run the test.

Setup the environment:
    Set-S3Test -RegionName us-west-1 -EndpointUrl https://s3.us-west-1.amazonaws.com -BucketName s3test -AccessKey EXAMPLE1WZRREXAMPLE -SecretKey EXAMPLEBIvvJe0Nogg7rvNbAeQEXAMPLE
    This example sets the tool to look for or create a bucket called "s3test" in the "us-west-1" region, with the specified endpoint & credentials.
    NOTE: Ensure your credentials have an IAM policy with ability to list the bucket(s), create bucket(s) [optionally], and write to the target bucket.

Start the test:
    Start-S3Test
    This example starts the test using default settings. See examples for more details & parameters.
.PARAMETER ModuleName
S3Benchmark
.PARAMETER Author
David Tosoff
.PARAMETER Description
This script will benchmark performance from a given machine, where it is run from, to an S3 target.
.PARAMETER Setup
Loads the script with an interactive setup prompt.
.PARAMETER StartTest
Starts the test using defaults upon loading the script. Implies -Setup.
.EXAMPLE
    Start-S3Test -BlockSizeKB 2048 -UploadFromFileSystem -WorkingDirectory D:\S3test -NumberOfFiles 1024 -MaxThreads 16
    This example starts the test using a 2048KB (2MB) block size, optionally specifies that it should perform the upload of 1024 files generated in D:\S3test, and tha is should do that across 16 parallel jobs/tasks/threads

    Start-S3Test -BlockSizeKB 512 -WorkingDirectory D:\S3test -NumberOfFiles 2048 -MaxThreads 48
    This example starts the test using a 512KB (0.5MB) block size, uses the default behaviour to perform the creation of 2048 objects from content generated in-memory, and that is should do that across 48 parallel jobs/tasks/threads

    Parameters: 
        -BlockSizeKB [block_size_value_in_KB]     (Sets the block/object size that should be used to test uploads, in KB; DEFAULT: 2048 [2MB])
        -UploadFromFileSystem                     (Flag to generate content to disk and upload from disk; DEFAULT: Content generation & upload from RAM)
        -WorkingDirectory [path_to_directory]     (Sets the working directory where the tool should place files; DEFAULT: C:\S3Test)
        -NumberOfFiles [value]                    (Sets the number of files to generate; DEFAULT: Based on block size to generate 1GB worth of files)
        -MaxThreads [value]                       (Sets the number of parallel processes perform upload; DEFAULT: Based on block size or CPU cores)
.NOTES
* The AWS.Tools.S3 powershell module, published by AWS, is required to run this tool. You will have to install it manually before running.
    e.g. Install-Module AWS.Tools.S3
* Ensure your credentials have an IAM policy with ability to list the bucket(s), create bucket(s) [optionally], and write to the target bucket.
* Thread count is a bit subjective, and may require trying a few options. I have
* If using this tool to troubleshoot performance, the main 4 potential bottlenecks that this test may help identify are:
    [DISK]-->[Machine (CPU/Mem)]-->[Network]-->[Bucket]
* When troubleshooting for performance, it is recommended to run the test in both in-memory (default) and from-disk (-UploadFromFileSystem) modes to give you an indication of whether the bottleneck is disk-bound or not.
* While the test is being run, it is recommended to watch Task Manager or Resource Manager to see how resources are being utilized.
.LINK
https://github.com/drtcode/S3Benchmark
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory=$False)]
    [switch]$Setup,

    [Parameter(Mandatory=$False)]
    [switch]$StartTest
)

# Bucket check/create-if-missing
function Test-S3Bucket {
    try {
        $buckets = Get-S3Bucket  -EndpointUrl $ENDPOINT_URL -ProfileName $PROFILE_NAME -Region $REGION

        if ($TEST_BUCKET_NAME -notin $buckets.BucketName) {
            New-S3Bucket -BucketName $TEST_BUCKET_NAME -EndpointUrl $ENDPOINT_URL -Region $REGION -ProfileName $PROFILE_NAME
        }
    } catch {
        Write-Host -ForegroundColor Yellow "Error finding or creating bucket. `r`n`tPlease confirm endpoint URL, region, credentials, and IAM policies are correct."
        exit 4
    }
}

# Job/Thread code
$Job = {
    param($PROFILE_NAME, $TEST_BUCKET_NAME, $ENDPOINT_URL, $REGION, $TEST_FILES_PATH, $BLOCK_SIZE, $NumberOfFiles, $FromFileSystem=$false)

    try {
        # Give thread/self higher priority in CPU
        (Get-Process -Id  $pid).PriorityClass = [System.Diagnostics.ProcessPriorityClass]::AboveNormal
        
        $ProgressPreference = "SilentlyContinue"

        Set-Location -Path $TEST_FILES_PATH

        Import-Module AWS.Tools.S3 | Out-Null
        
        # Block that will execute the file upload
        $ScriptBlock =  {
            param($PROFILE_NAME, $TEST_BUCKET_NAME, $ENDPOINT_URL, $REGION, $TEST_FILES_PATH, $Content)

            $prefix = (Get-Random -InputObject (0..128)).ToString()
            $fileName = [guid]::NewGuid().Guid.ToString()

            # if the $content variable is a filename ending with .bin, then upload files from disk; vs if its just random bytes, upload the bytes from memory
            if ($content.EndsWith(".bin")) {
                $result = (Measure-Command {
                    Write-S3Object -BucketName $TEST_BUCKET_NAME -Key ($prefix+"/"+$fileName) `
                        -File $Content `
                        -EndpointUrl $ENDPOINT_URL -Region $REGION -ProfileName $PROFILE_NAME # -Verbose *> ("$TEST_FILES_PATH\job_"+$file.Name+".log")
                }).TotalMilliseconds
            } else {
                $result = (Measure-Command {
                    Write-S3Object -BucketName $TEST_BUCKET_NAME -Key ($prefix+"/"+$fileName) `
                        -Content $Content `
                        -EndpointUrl $ENDPOINT_URL -Region $REGION -ProfileName $PROFILE_NAME # -Verbose *> ("$TEST_FILES_PATH\job_"+$file.Name+".log")
                }).TotalMilliseconds
            }

            # Return how long the upload took.
            return $result
        }

        
        # Generate random bytes to create as files/objects
        $contents = @()
        1..$NumberOfFiles | ForEach-Object {
            $out = new-object byte[] $BLOCK_SIZE;
            (new-object Random).NextBytes($out);

            # Check if the test should upload from memory or from filesystem; if filesystem then write the generated content out.
            if ($FromFileSystem) {
                $fileName = [guid]::NewGuid().Guid.ToString()
                $filesPath = "$Global:TEST_FILES_PATH\$pid"
                if (!(Test-Path $filesPath)) {
                    New-Item -ItemType Directory $filesPath | Out-Null
                }
                [IO.File]::WriteAllBytes("$filesPath\$fileName.bin", $out) | Out-Null
                $contents += "$filesPath\$fileName.bin"
            } else {
                $contents += [System.Text.Encoding]::ASCII.GetString($out)
            }
        }
    } catch {
        Write-Output "`tThread preparation Failed. PID: $pid, From Files: $FromFileSystem"
    }

    # Once all of the above is done, signal back to main process that this job/thread is ready, and await signal file to start concurrently with all other threads.
    Write-Output "`tThread Ready. PID: $pid, From Files: $FromFileSystem"
    while (!(Test-Path .\startS3test)) {
        Start-Sleep -Milliseconds 500 | Out-Null
    }

    # Start executing the file uploads.
    $results = @()
    1..$NumberOfFiles | ForEach-Object {
        $results += & $ScriptBlock $PROFILE_NAME $TEST_BUCKET_NAME $ENDPOINT_URL $REGION $TEST_FILES_PATH $contents[($_-1)]
    }

    # Clean up files, if generated.
    if ($FromFileSystem) {
        $filesPath | Remove-Item -Recurse -Force
    }

    # Return results back to parent thread/main script of how long each upload took.
    return $results
}

# Setup the test environment details.
function Set-S3Test ($RegionName=(Read-Host -Prompt 'Region Name'), $EndpointUrl=(Read-Host -Prompt 'Endpoint URL'), $BucketName=(Read-Host -Prompt 'Bucket Name'), $AccessKey=(Read-Host -Prompt 'Access Key'), $SecretKey=(Read-Host -Prompt 'Secret Key')) {
    $Global:IsSetup = $false
    # Check if main AWS module is detected. Don't run if so -- it's way too heavy.
    $hasAWSModule = (get-module -ListAvailable -Name AWSPowerShell).Count -gt 0
    if ($hasAWSModule) {
        Write-Host -ForegroundColor Yellow "Module 'AWSPowerShell' detected! This module is very heavy and will cause this tool to not operate well. `r`n`tRun this tool on another system, or uninstall this module `r`n`t(Command: Uninstall-Module AWSPowerShell)"
        exit 2
    }
    # Check if just the S3 module is detected. Don't run if its missing. It's required.
    $hasS3Module = (get-module -ListAvailable -Name AWS.Tools.S3).Count -gt 0
    if (!$hasS3Module) {
        Write-Host -ForegroundColor Yellow "Module 'AWS.Tools.S3' was not detected. This module is required.`r`n`tPlease install this module first `r`n`t(Command: Install-Module AWS.Tools.S3)"
        exit 3
    } else {
        Import-Module AWS.Tools.S3
    }

    # Set keys in memory
    $Global:ACCESS_KEY = $AccessKey
    $Global:SECRET_KEY = $SecretKey

    # Set some global variables.
    $Global:PROFILE_NAME = "s3test"
    $Global:TEST_BUCKET_NAME = $BucketName
    $Global:REGION = $RegionName
    $Global:ENDPOINT_URL = $EndpointUrl # e.g. "https://s3.us-west-1.wasabisys.com"

    # Create AWS credential, test if S3 bucket is ready, and clear AWS credential.
    Set-AWSCredential -AccessKey $Global:ACCESS_KEY -SecretKey $Global:SECRET_KEY -StoreAs $Global:PROFILE_NAME
    Test-S3Bucket
    Remove-AWSCredentialProfile -ProfileName $Global:PROFILE_NAME -Force

    # Signal that setup is ready/run.
    $Global:IsSetup = $true

    Write-Host -ForegroundColor Cyan "Test environment configured."

    if (!$StartTest) {
    Write-Host -ForegroundColor Cyan -NoNewline "Please run '"
    Write-Host -ForegroundColor Magenta -NoNewline "Start-S3Test"
    Write-Host -ForegroundColor Cyan "' to start/perform the benchmark test. `
    Parameters: `
        -BlockSizeKB [block_size_value_in_KB]`r`n`t   (Sets the block/object size that should be used to test uploads, in KB; DEFAULT: 2048 [2MB]) `
        -UploadFromFileSystem`r`n`t   (Flag to generate content to disk and upload from disk; DEFAULT: Content generation & upload from RAM) `
        -WorkingDirectory [path_to_directory]`r`n`t   (Sets the working directory where the tool should place files; DEFAULT: C:\S3Test) `
        -NumberOfFiles [value]`r`n`t   (Sets the number of files to generate; DEFAULT: Based on block size to generate 1GB worth of files) `
        -MaxThreads [value]`r`n`t   (Sets the number of parallel processes perform upload; DEFAULT: Based on block size or CPU cores)`r`n"
    }
}

# The main test block
function Start-S3Test ($BlockSizeKB=2048, [switch]$UploadFromFileSystem, $WorkingDirectory="C:\S3Test", $NumberOfFiles=0, $MaxThreads=0) {
    try {
        # Check if Set-S3Test has been run.
        if (!$Global:IsSetup) {
            Write-Warning "Please run Set-S3Test first."
            return }
        
        # Set Defaults
        if ($MaxThreads -eq 0) {
            $MaxThreads = [Math]::Min(48/($BlockSizeKB/512),((Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors*6))   # Set max threads to the lesser of a normalized 48 per 512k block or # of cores x6
        }
        if ($NumberOfFiles -eq 0) {
            $NumberOfFiles = 1048576/$BlockSizeKB   # Set to 1GB worth of test data.
        }

        # Warn if large test
        $testConsumption = $NumberOfFiles*$BlockSizeKB/1024/1024
        if ($testConsumption -ge 2) {
            if ($UploadFromFileSystem) {
                Write-Host -ForegroundColor Magenta "`tThis test will temporarily generate $([math]::Round($testConsumption,2)) GB of files @ '$WorkingDirectory'"
            } else {
                Write-Host -ForegroundColor Magenta "`tThis test will consume > $([math]::Round($testConsumption,2)) GB of RAM"
            }
            Write-Host -ForegroundColor Magenta -NoNewline "`tPress any key to proceed, or CTRL+C to cancel."
            Read-Host
        }

        # Start test
        Write-Host -ForegroundColor Yellow "Starting test... Files: $NumberOfFiles, Threads: $MaxThreads, Block Size: $BlockSizeKB, Working Directory: $WorkingDirectory, Upload From Filesystem: $UploadFromFileSystem"

        $Global:BLOCK_SIZE = $BlockSizeKB*1024
        $Global:NUMBER_OF_FILES = $NumberOfFiles
        $Global:TEST_FILES_PATH = $WorkingDirectory
        
        # Check if working directory exists or create it.
        if (!(Test-Path $Global:TEST_FILES_PATH)) {
            New-Item -ItemType Directory $Global:TEST_FILES_PATH | Out-Null
        }
        
        $Global:MAX_THREADS = $MaxThreads
        $Global:FILES_PER_THREAD = $Global:NUMBER_OF_FILES/$Global:MAX_THREADS


        $jobs = @()
        $results = @()
        Set-AWSCredential -AccessKey $Global:ACCESS_KEY -SecretKey $Global:SECRET_KEY -StoreAs $Global:PROFILE_NAME

        # Start a new job for the defined amount of threads to be used.
        1..$MAX_THREADS | ForEach-Object {
            $jobs += Start-Job -Name ("S3Tester_"+$_) -ScriptBlock $Job -ArgumentList $Global:PROFILE_NAME, $Global:TEST_BUCKET_NAME, $Global:ENDPOINT_URL, $Global:REGION, $Global:TEST_FILES_PATH, $Global:BLOCK_SIZE, $Global:FILES_PER_THREAD, $UploadFromFileSystem
        }

        
        Write-Host -ForegroundColor Yellow  'All jobs initialized. Syncing...'

        # Check and wait until all jobs/threads are ready or have failed
        $readyJobs = @()
        while ($readyJobs.Count -lt $Global:MAX_THREADS) {
            get-job -State Running -HasMoreData:$true | Where-Object { $_.Name -in $jobs.Name } | ForEach-Object {
                $_ | Receive-Job -OutVariable state
                if (($state -join ";").Contains("Ready.")) { $readyJobs += @{Name=$_.Name;State=$state}; }
                if (($state -join ";").Contains("Failed.")) {
                    Write-Error "Error preparing threads. Please try again."
                    exit 98
                }
            }
            Start-Sleep -Seconds 2
        }

        Write-Host -ForegroundColor Yellow  'All jobs ready. Running test...'
        New-Item -Path ($Global:TEST_FILES_PATH+"\starts3test") | Out-Null      #Create signal file for all jobs/threads to start/execute upload.

        # While we wait for the jobs to finish, capture bytes sent from network adapters.
        $Global:AdapterStats = @();
        while (($jobs | get-job | Where-Object { $_.State -ne "Completed" }).Count -gt 0) {

            $sleepPeriod = 2

            $StartAdapterStats = Get-NetAdapterStatistics
            Start-Sleep -Seconds $sleepPeriod
            $EndAdapterStats = Get-NetAdapterStatistics

            $Global:AdapterStats += $EndAdapterStats | Select-Object Name,@{n="Mbps";e={$name=$_.Name;(($_.SentBytes-($StartAdapterStats | Where-Object {$_.Name -eq $name }).SentBytes)/1024/1024*8)/$sleepPeriod}}
        }

        #Remove-Item -Path ($Global:TEST_FILES_PATH+"\starts3test") -Force | Out-Null    # Once all jobs/threads complete, cleanup signal file

        get-job -State Completed | Where-Object { $_.Name -in $jobs.Name } | ForEach-Object { $results += $_ | Receive-Job }    # Collect all job/thread results
        get-job -State Completed -HasMoreData:$false  | Where-Object { $_.Name -in $jobs.Name } | Remove-Job    # Cleanup jobs

        # Calculate average & max throughput of all concurrent threads.
        $throughput = (($Global:NUMBER_OF_FILES*$Global:BLOCK_SIZE)/1024/1024)/(($results | Measure-Object -sum).Sum/$Global:MAX_THREADS/1000)
        $maxThrough = ($Global:AdapterStats | Measure-Object Mbps -Maximum -Average -Minimum | Select-Object Property,Maximum).Maximum

        # Report stats
        Write-Host
        Write-Host -NoNewline  "`tAverage Throughput (MB/s):`t"
        Write-Host -ForegroundColor Cyan ([math]::Round($throughput,2))
        Write-Host -NoNewline  "`tMax Throughput (MB/s):`t`t"
        Write-Host -ForegroundColor Cyan ([math]::Round($maxThrough/8,2))
        Write-Host "`t --------------------"
        Write-Host -NoNewline "`tAverage Throughput (Mbps):`t"
        Write-Host -ForegroundColor Cyan ([math]::Round($throughput*8,2))
        Write-Host -NoNewline  "`tMax Throughput (Mbps):`t`t"
        Write-Host -ForegroundColor Cyan ([math]::Round($maxThrough,2))
        Write-Host
            
    } finally {
        Write-Host -ForegroundColor Yellow -NoNewline 'Cleaning up'
        Write-Host -ForegroundColor Yellow -NoNewline '.'
        Remove-AWSCredentialProfile -ProfileName $Global:PROFILE_NAME -Force -ErrorAction SilentlyContinue | Out-Null # Cleanup AWS credentials
        
        Write-Host -ForegroundColor Yellow -NoNewline '.'
        get-job | Where-Object { $_.Name -in $jobs.Name } | Remove-Job -Force -ErrorAction SilentlyContinue | Out-Null # Cleanup jobs
        
        # Remove all folders that no longer have pids.
        Write-Host -ForegroundColor Yellow -NoNewline '.'
        $pidFiles = get-childitem $Global:TEST_FILES_PATH -Directory
        $procs = $pidFiles | ForEach-Object { Get-Process -Id $_.Name -ErrorAction SilentlyContinue }
        Write-Host -ForegroundColor Yellow -NoNewline '.'
        $pidFiles | Where-Object { $_.Name -notin $procs.Id } | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
        
        Write-Host -ForegroundColor Yellow -NoNewline '.'
        Remove-Item -Path ($Global:TEST_FILES_PATH+"\starts3test") -Force -ErrorAction SilentlyContinue | Out-Null    # Once all jobs/threads complete, cleanup signal file

        Write-Host -ForegroundColor Yellow " Done`r`n"
    }
}

Write-Host -ForegroundColor Cyan "S3Test functions loaded."
if ($Setup) {
    Set-S3Test
} else {
    
    Write-Host -ForegroundColor Cyan -NoNewline "Please run '"
    Write-Host -ForegroundColor Magenta -NoNewline "Set-S3Test"
    Write-Host -ForegroundColor Cyan "' to configure the test environment. `r`n`tE.g. Set-S3Test -RegionName us-west-1 -EndpointUrl https://s3.us-west-1.amazonaws.com -BucketName s3test -AccessKey EXAMPLE1WZRREXAMPLE -SecretKey EXAMPLEBIvvJe0Nogg7rvNbAeQEXAMPLE`r`n"
}

if ($StartTest) {
    if (!$Global:IsSetup) {
        Set-S3Test
    }
    Start-S3Test
}