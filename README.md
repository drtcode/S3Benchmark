# S3Benchmark
Generates random data of a specific size and uploads it to an S3 bucket.

## Description
This script will benchmark performance from a given machine, where it is run from, to an S3 target.
After configuring the target environment, the test can perform the uploads directly from memory or can optionally be instructed to perform the uploads from a disk target.
By using the default in-memory data generation & upload, the disk is bypassed, thereby eliminating it as a potential bottleneck.

## Prerequisites
* The AWS.Tools.S3 powershell module, published by AWS, is required to run this tool. You will have to install it manually before running:

      Install-Module AWS.Tools.S3
* Ensure your credentials have an IAM policy with ability to list the bucket(s), create bucket(s) [optionally], and write to the target bucket.

## Usage:
#### Load the module:
    . .\S3Benchmark.ps1
Optionally, you can set the -Setup and/or -StartTest switches to immediately setup & run the test.

    . .\S3Benchmark.ps1 -Setup
OR

    . .\S3Benchmark.ps1 -StartTest

    
#### Setup the environment:
    Set-S3Test -RegionName us-west-1 -EndpointUrl https://s3.us-west-1.amazonaws.com -BucketName s3test -AccessKey EXAMPLE1WZRREXAMPLE -SecretKey EXAMPLEBIvvJe0Nogg7rvNbAeQEXAMPLE
 This example sets the tool to look for or create a bucket called "s3test" in the "us-west-1" region, with the specified endpoint & credentials.
    NOTE: Ensure your credentials have an IAM policy with ability to list the bucket(s), create bucket(s) [optionally], and write to the target bucket.
    
#### Start the test:
    Start-S3Test
This example starts the test using default settings. See examples for more details & parameters.

## Start-S3Test Examples
    Start-S3Test -BlockSizeKB 2048 -UploadFromFileSystem -WorkingDirectory D:\S3test -NumberOfFiles 1024 -MaxThreads 16
This example starts the test using a 2048KB (2MB) block size, optionally specifies that it should perform the upload of 1024 files generated in D:\S3test, and tha is should do that across 16 parallel jobs/tasks/threads

    Start-S3Test -BlockSizeKB 512 -WorkingDirectory D:\S3test -NumberOfFiles 2048 -MaxThreads 48
This example starts the test using a 512KB (0.5MB) block size, uses the default behaviour to perform the creation of 2048 objects from content generated in-memory, and that is should do that across 48 parallel jobs/tasks/threads

#### Start-S3Test Parameters: 
        -BlockSizeKB [block_size_value_in_KB]     (Sets the block/object size that should be used to test uploads, in KB; DEFAULT: 2048 [2MB])
        -UploadFromFileSystem                     (Flag to generate content to disk and upload from disk; DEFAULT: Content generation & upload from RAM)
        -WorkingDirectory [path_to_directory]     (Sets the working directory where the tool should place files; DEFAULT: C:\S3Test)
        -NumberOfFiles [value]                    (Sets the number of files to generate; DEFAULT: Based on block size to generate 1GB worth of files)
        -MaxThreads [value]                       (Sets the number of parallel processes perform upload; DEFAULT: Based on block size or CPU cores)

## NOTES
* Ensure your credentials have an IAM policy with ability to list the bucket(s), create bucket(s) [optionally], and write to the target bucket.
* If using this tool to troubleshoot performance, the main 4 potential bottlenecks that this test may help identify are:
    * [DISK]-->[Machine (CPU/Mem)]-->[Network]-->[Bucket]
* When troubleshooting for performance, it is recommended to run the test in both in-memory (default) and from-disk (-UploadFromFileSystem) modes to give you an indication of whether the bottleneck is disk-bound or not.
* While the test is being run, it is recommended to watch Task Manager or Resource Manager to see how resources are being utilized.
