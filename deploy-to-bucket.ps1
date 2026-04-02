# Скрипт для быстрого деплоя статического сайта в bucket
# Использование: .\deploy-to-bucket.ps1 [-MaxParallel <число>] [-Force] [-BucketName <имя>] [-SourcePath <путь>] [-MaxRetries <число>] [-RetryDelaySec <число>]
#   -MaxParallel: количество параллельных загрузок (по умолчанию: 5)
#   -Force: принудительная замена всех файлов, даже если они уже существуют в bucket
#   -BucketName: имя bucket (по умолчанию: afaml.ru)
#   -SourcePath: путь к папке с сайтом (по умолчанию: текущая папка, сайт без сборки)
#   -MaxRetries: число повторных попыток при ошибке сети/YC (по умолчанию: 3)
#   -RetryDelaySec: пауза между попытками в секундах (по умолчанию: 2)

param(
    [int]$MaxParallel = 5,
    [switch]$Force,
    [string]$BucketName = "afaml.ru",
    [string]$SourcePath = ".",
    [int]$MaxRetries = 3,
    [int]$RetryDelaySec = 2
)

$ErrorActionPreference = "Stop"

# Подавить предупреждение YC о недоступности сервиса инициализации (изолированная среда)
if (-not $env:YC_CLI_INITIALIZATION_SILENCE) {
    $env:YC_CLI_INITIALIZATION_SILENCE = "true"
}

$bucketName = $BucketName
$sourceRoot = $SourcePath
if (-not (Test-Path $sourceRoot)) {
    Write-Host "❌ Папка с сайтом не найдена: $sourceRoot" -ForegroundColor Red
    exit 1
}
$sourceRoot = (Resolve-Path $sourceRoot).Path
$env:YC_BUCKET_NAME = $bucketName

Write-Host "🚀 Деплой в bucket: $bucketName" -ForegroundColor Green
Write-Host "📁 Источник файлов: $sourceRoot" -ForegroundColor Gray
if ($Force) {
    Write-Host "⚠️  Режим принудительной замены всех файлов включен" -ForegroundColor Yellow
}
Write-Host ""

# Выполнение команды с повторными попытками при ошибке
function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$Attempts = $MaxRetries,
        [int]$DelaySeconds = $RetryDelaySec,
        [string]$OperationName = "Операция"
    )
    $attempt = 0
    while ($true) {
        try {
            $attempt++
            $result = & $ScriptBlock
            return $result
        } catch {
            if ($attempt -ge $Attempts) {
                Write-Host "❌ $OperationName не удалась после $Attempts попыток" -ForegroundColor Red
                throw
            }
            Write-Host "⚠️  $OperationName — ошибка (попытка $attempt/$Attempts): $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "   Повтор через ${DelaySeconds} с..." -ForegroundColor Gray
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

# Проверка YC CLI
if (-not (Get-Command yc -ErrorAction SilentlyContinue)) {
    Write-Host "❌ Yandex Cloud CLI не найден" -ForegroundColor Red
    Write-Host "Убедитесь, что YC CLI установлен и доступен в PATH" -ForegroundColor Yellow
    exit 1
}

# Проверка bucket
Write-Host "📦 Проверка bucket..." -ForegroundColor Cyan
try {
    Invoke-WithRetry -ScriptBlock {
        yc storage bucket get --name $bucketName | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "yc завершился с кодом $LASTEXITCODE" }
    } -OperationName "Проверка bucket"
    Write-Host "✅ Bucket найден" -ForegroundColor Green
} catch {
    Write-Host "❌ Bucket `"$bucketName`" не найден или нет доступа" -ForegroundColor Red
    exit 1
}

# Функция для определения MIME-типа по расширению файла
function Get-MimeType {
    param([string]$Extension)

    $mimeTypes = @{
        '.html' = 'text/html; charset=utf-8'
        '.htm' = 'text/html; charset=utf-8'
        '.js' = 'application/javascript; charset=utf-8'
        '.mjs' = 'application/javascript; charset=utf-8'
        '.css' = 'text/css; charset=utf-8'
        '.json' = 'application/json; charset=utf-8'
        '.png' = 'image/png'
        '.jpg' = 'image/jpeg'
        '.jpeg' = 'image/jpeg'
        '.gif' = 'image/gif'
        '.svg' = 'image/svg+xml'
        '.webp' = 'image/webp'
        '.ico' = 'image/x-icon'
        '.woff' = 'font/woff'
        '.woff2' = 'font/woff2'
        '.ttf' = 'font/ttf'
        '.eot' = 'application/vnd.ms-fontobject'
        '.otf' = 'font/otf'
        '.xml' = 'application/xml'
        '.txt' = 'text/plain; charset=utf-8'
        '.pdf' = 'application/pdf'
        '.zip' = 'application/zip'
    }

    $ext = $Extension.ToLower()
    if ($mimeTypes.ContainsKey($ext)) {
        return $mimeTypes[$ext]
    }
    return 'application/octet-stream'
}

# Функция для загрузки одного файла
function Upload-File {
    param(
        [string]$BucketName,
        [string]$RelativePath,
        [string]$LocalPath,
        [string]$ContentType
    )

    try {
        yc storage s3api put-object `
            --bucket $BucketName `
            --key "$RelativePath" `
            --body "$LocalPath" `
            --content-type "$ContentType" | Out-Null

        return @{ Success = $true; Path = $RelativePath }
    } catch {
        return @{ Success = $false; Path = $RelativePath; Error = $_.Exception.Message }
    }
}

# Функция для параллельной загрузки файлов
function Upload-FilesParallel {
    param(
        [array]$Files,
        [string]$BucketName,
        [string]$DistPath,
        [int]$MaxParallel,
        [string]$Label = "файлов",
        [int]$Retries = $MaxRetries,
        [int]$RetryDelay = $RetryDelaySec
    )

    $uploaded = 0
    $failed = 0
    $skipped = 0
    $total = $Files.Count
    $jobs = @()
    $jobIndex = 0

    # Создаем пул задач
    while ($jobIndex -lt $total) {
        # Ждем, пока освободится место в пуле
        while ($jobs.Count -ge $MaxParallel) {
            $completed = $jobs | Where-Object { $_.State -eq 'Completed' -or $_.State -eq 'Failed' }
            foreach ($job in $completed) {
                $result = Receive-Job -Job $job
                Remove-Job -Job $job
                $jobs = @($jobs | Where-Object { $_.Id -ne $job.Id })

                if ($result.Success) {
                    $uploaded++
                    Write-Host "📤 Загружен ($uploaded/$total): $($result.Path)" -ForegroundColor Gray
                } elseif ($result.Skipped) {
                    $skipped++
                    Write-Host "⏭️  Пропущен ($skipped/$total): $($result.Path)" -ForegroundColor DarkGray
                } else {
                    $failed++
                    Write-Host "❌ Ошибка ($failed/$total): $($result.Path)" -ForegroundColor Red
                    Write-Host "   $($result.Error)" -ForegroundColor DarkRed
                }
            }

            if ($jobs.Count -ge $MaxParallel) {
                Start-Sleep -Milliseconds 100
            }
        }

        # Запускаем новую задачу
        $file = $Files[$jobIndex]
        $relativePath = $file.FullName.Substring($DistPath.Length + 1).Replace('\', '/')
        $localPath = $file.FullName
        $extension = [System.IO.Path]::GetExtension($file.Name)
        $contentType = Get-MimeType -Extension $extension

        $scriptBlock = {
            param($b, $rp, $lp, $ct, $maxRetries, $retryDelaySec)
            $attempt = 0
            while ($true) {
                $attempt++
                yc storage s3api put-object `
                    --bucket $b `
                    --key $rp `
                    --body $lp `
                    --content-type $ct 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    return @{ Success = $true; Path = $rp; Skipped = $false }
                }
                $errMsg = "yc завершился с кодом $LASTEXITCODE"
                if ($attempt -ge $maxRetries) {
                    return @{ Success = $false; Path = $rp; Skipped = $false; Error = $errMsg }
                }
                Start-Sleep -Seconds $retryDelaySec
            }
        }

        $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList $BucketName, $relativePath, $localPath, $contentType, $Retries, $RetryDelay
        $jobs = @($jobs) + $job
        $jobIndex++
    }

    # Ждем завершения всех оставшихся задач
    while ($jobs.Count -gt 0) {
        $completed = $jobs | Where-Object { $_.State -eq 'Completed' -or $_.State -eq 'Failed' }
        foreach ($job in $completed) {
            $result = Receive-Job -Job $job
            Remove-Job -Job $job
            $jobs = @($jobs | Where-Object { $_.Id -ne $job.Id })

            if ($result.Success) {
                $uploaded++
                Write-Host "📤 Загружен ($uploaded/$total): $($result.Path)" -ForegroundColor Gray
            } elseif ($result.Skipped) {
                $skipped++
                Write-Host "⏭️  Пропущен ($skipped/$total): $($result.Path)" -ForegroundColor DarkGray
            } else {
                $failed++
                Write-Host "❌ Ошибка ($failed/$total): $($result.Path)" -ForegroundColor Red
                Write-Host "   $($result.Error)" -ForegroundColor DarkRed
            }
        }

        if ($jobs.Count -gt 0) {
            Start-Sleep -Milliseconds 100
        }
    }

    return @{
        Uploaded = $uploaded
        Failed = $failed
        Skipped = $skipped
        Total = $total
    }
}

# Функция для параллельного удаления файлов
function Delete-FilesParallel {
    param(
        [array]$FileKeys,
        [string]$BucketName,
        [int]$MaxParallel,
        [int]$Retries = $MaxRetries,
        [int]$RetryDelay = $RetryDelaySec
    )

    $deleted = 0
    $failed = 0
    $total = $FileKeys.Count
    $jobs = @()
    $jobIndex = 0

    # Создаем пул задач
    while ($jobIndex -lt $total) {
        # Ждем, пока освободится место в пуле
        while ($jobs.Count -ge $MaxParallel) {
            $completed = $jobs | Where-Object { $_.State -eq 'Completed' -or $_.State -eq 'Failed' }
            foreach ($job in $completed) {
                $result = Receive-Job -Job $job
                Remove-Job -Job $job
                $jobs = @($jobs | Where-Object { $_.Id -ne $job.Id })

                if ($result.Success) {
                    $deleted++
                    Write-Host "🗑️  Удален ($deleted/$total): $($result.Key)" -ForegroundColor Gray
                } else {
                    $failed++
                    Write-Host "❌ Ошибка при удалении ($failed/$total): $($result.Key)" -ForegroundColor Red
                    Write-Host "   $($result.Error)" -ForegroundColor DarkRed
                }
            }

            if ($jobs.Count -ge $MaxParallel) {
                Start-Sleep -Milliseconds 100
            }
        }

        # Запускаем новую задачу
        $key = $FileKeys[$jobIndex]

        $scriptBlock = {
            param($b, $k, $maxRetries, $retryDelaySec)
            $attempt = 0
            while ($true) {
                $attempt++
                yc storage s3api delete-object --bucket $b --key $k 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    return @{ Success = $true; Key = $k }
                }
                $errMsg = "yc завершился с кодом $LASTEXITCODE"
                if ($attempt -ge $maxRetries) {
                    return @{ Success = $false; Key = $k; Error = $errMsg }
                }
                Start-Sleep -Seconds $retryDelaySec
            }
        }

        $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList $BucketName, $key, $Retries, $RetryDelay
        $jobs = @($jobs) + $job
        $jobIndex++
    }

    # Ждем завершения всех оставшихся задач
    while ($jobs.Count -gt 0) {
        $completed = $jobs | Where-Object { $_.State -eq 'Completed' -or $_.State -eq 'Failed' }
        foreach ($job in $completed) {
            $result = Receive-Job -Job $job
            Remove-Job -Job $job
            $jobs = @($jobs | Where-Object { $_.Id -ne $job.Id })

            if ($result.Success) {
                $deleted++
                Write-Host "🗑️  Удален ($deleted/$total): $($result.Key)" -ForegroundColor Gray
            } else {
                $failed++
                Write-Host "❌ Ошибка при удалении ($failed/$total): $($result.Key)" -ForegroundColor Red
                Write-Host "   $($result.Error)" -ForegroundColor DarkRed
            }
        }

        if ($jobs.Count -gt 0) {
            Start-Sleep -Milliseconds 100
        }
    }

    return @{
        Deleted = $deleted
        Failed = $failed
        Total = $total
    }
}

# Функция для нормализации имени файла (для корректного сравнения)
function Normalize-FileName {
    param([string]$FileName)
    
    if ([string]::IsNullOrEmpty($FileName)) {
        return $FileName
    }
    
    # Пробуем декодировать URL-encoded имена (если есть)
    try {
        $decoded = [System.Uri]::UnescapeDataString($FileName)
        if ($decoded -ne $FileName) {
            return $decoded
        }
    } catch {
        # Игнорируем
    }
    
    return $FileName
}

# Функция для исправления кодировки имени файла из bucket
function Fix-BucketFileNameEncoding {
    param([string]$FileName)
    
    if ([string]::IsNullOrEmpty($FileName)) {
        return $FileName
    }
    
    # Пробуем исправить кодировку: если имя выглядит как неправильно закодированная UTF-8
    # (интерпретированная как Windows-1252 или другая кодировка)
    try {
        # Конвертируем строку в байты, предполагая Windows-1252
        $bytes = [System.Text.Encoding]::GetEncoding("Windows-1252").GetBytes($FileName)
        # Декодируем как UTF-8
        $utf8String = [System.Text.Encoding]::UTF8.GetString($bytes)
        
        # Проверяем, содержит ли результат нормальные кириллические символы
        if ($utf8String -match '[а-яА-ЯёЁ]') {
            return $utf8String
        }
    } catch {
        # Игнорируем ошибки
    }
    
    return $FileName
}

# Получение списка существующих файлов в bucket (нужно для удаления старых файлов и проверки при отсутствии -Force)
Write-Host "📋 Получение списка существующих файлов в bucket..." -ForegroundColor Cyan
$existingFiles = @{}  # Оригинальные имена из bucket
$existingFileSizes = @{}
$existingFilesNormalized = @{}  # Нормализованные имена для сравнения
$fixedToOriginalMapping = @{}  # Маппинг исправленных имен к оригинальным
try {
    # Устанавливаем UTF-8 кодировку для вывода
    $OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    
    # Формат YAML для вывода list-objects
    $env:YC_FORMAT = "yaml"
    try {
        $yamlOutput = Invoke-WithRetry -ScriptBlock {
            $out = yc storage s3api list-objects --bucket $bucketName 2>&1 | Out-String -Width 4096
            if ($LASTEXITCODE -ne 0) { throw "yc завершился с кодом $LASTEXITCODE" }
            $out
        } -OperationName "Получение списка файлов в bucket"
    } finally {
        $env:YC_FORMAT = $null
    }

    if ($yamlOutput) {
        # Парсинг YAML: строки с "key:" и "size:"
        $yamlLines = $yamlOutput -split "`n"
        $currentKey = $null
        foreach ($line in $yamlLines) {
            if ($line -match '^\s+-\s+key:\s+(.+)$') {
                $currentKey = $matches[1].Trim()
                if ($currentKey) {
                    if ($currentKey -match '^["''](.+)["'']$') {
                        $currentKey = $matches[1]
                    }
                    $existingFiles[$currentKey] = $true
                    $fixedKey = Fix-BucketFileNameEncoding -FileName $currentKey
                    if ($fixedKey -ne $currentKey) {
                        $fixedToOriginalMapping[$fixedKey] = $currentKey
                    }
                    $normalizedKey = Normalize-FileName -FileName $fixedKey
                    $existingFilesNormalized[$normalizedKey] = $currentKey
                }
            } elseif ($currentKey -and $line -match '^\s+size:\s+(\d+)$') {
                $existingFileSizes[$currentKey] = [long]$matches[1]
                $currentKey = $null
            }
        }
        if ($existingFiles.Count -gt 0) {
            Write-Host "✅ Найдено существующих файлов: $($existingFiles.Count)" -ForegroundColor Green
        } else {
            Write-Host "ℹ️  Bucket пуст или не содержит файлов" -ForegroundColor Gray
        }
    } else {
        Write-Host "ℹ️  Bucket пуст или не содержит файлов" -ForegroundColor Gray
    }
} catch {
    Write-Host "⚠️  Не удалось получить список файлов, продолжаем деплой без очистки старых файлов" -ForegroundColor Yellow
    Write-Host $_.Exception.Message -ForegroundColor Gray
}
Write-Host ""

# Подготовка файлов для загрузки
$excludeDirNames = @(".git", ".github", ".vscode", "node_modules", "dist")
$excludeFileNames = @(
    "deploy-to-bucket.ps1",
    "package.json",
    "package-lock.json",
    "README.md",
    ".gitignore"
)

$allFiles = Get-ChildItem -Path $sourceRoot -Recurse -File | Where-Object {
    $relativePath = $_.FullName.Substring($sourceRoot.Length).TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($relativePath)) { return $false }
    $segments = $relativePath -split '\\'
    foreach ($segment in $segments) {
        if ($excludeDirNames -contains $segment) { return $false }
    }
    if ($excludeFileNames -contains $_.Name) { return $false }
    return $true
}

if ($allFiles.Count -eq 0) {
    Write-Host "❌ Не найдено файлов для деплоя в: $sourceRoot" -ForegroundColor Red
    exit 1
}

$newFiles = @()
$indexHtmlFiles = @()
$skippedFiles = 0

foreach ($file in $allFiles) {
    $relativePath = $file.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/')

    # index.html всегда загружаем, даже если он есть в bucket (для обновления контента)
    $isIndexHtml = $relativePath -match 'index\.html$'
    
    # Если флаг Force установлен, загружаем ВСЕ файлы, включая существующие (замена)
    # Если Force не установлен, проверяем существование файлов и пропускаем их
    if (-not $Force -and -not $isIndexHtml) {
        # Проверка наличия файла в bucket по имени (только для не-index.html файлов)
        # Используем нормализованные и исправленные имена для корректного сравнения с кириллицей
        $normalizedPath = Normalize-FileName -FileName $relativePath
        $fileExists = $false
        
        # Проверяем по оригинальному имени
        if ($existingFiles.ContainsKey($relativePath)) {
            $fileExists = $true
        }
        
        # Проверяем по исправленному имени (если файл был загружен с неправильной кодировкой)
        if (-not $fileExists -and $fixedToOriginalMapping.ContainsKey($relativePath)) {
            $fileExists = $true
        }
        
        # Проверяем по нормализованному имени
        if (-not $fileExists -and $existingFilesNormalized.ContainsKey($normalizedPath)) {
            $fileExists = $true
        }
        
        if ($fileExists) {
            # Файл уже есть в bucket - пропускаем (только если не установлен -Force)
            $skippedFiles++
            continue
        }
    }
    # При установленном -Force все файлы (включая существующие) будут загружены

    # Разделяем на index.html и остальные файлы
    if ($isIndexHtml) {
        $indexHtmlFiles += $file
    } else {
        $newFiles += $file
    }
}

$totalFiles = $allFiles.Count
$filesToUpload = $newFiles.Count + $indexHtmlFiles.Count
Write-Host "📦 Найдено файлов для загрузки: $filesToUpload из $totalFiles" -ForegroundColor Cyan
Write-Host "   - Обычные файлы: $($newFiles.Count)" -ForegroundColor Gray
Write-Host "   - index.html файлы: $($indexHtmlFiles.Count)" -ForegroundColor Gray
if ($skippedFiles -gt 0 -and -not $Force) {
    Write-Host "   - Пропущено (уже есть в bucket): $skippedFiles" -ForegroundColor DarkGray
}
if ($Force) {
    Write-Host "   - Режим: принудительная замена всех файлов" -ForegroundColor Yellow
}
Write-Host "   - Параллельных потоков: $MaxParallel" -ForegroundColor Gray
Write-Host ""

# Шаг 1: Загрузка всех файлов кроме index.html
if ($newFiles.Count -gt 0) {
    if ($Force) {
        Write-Host "☁️  Шаг 1: Загрузка всех файлов (кроме index.html) с заменой существующих..." -ForegroundColor Cyan
    } else {
        Write-Host "☁️  Шаг 1: Загрузка новых файлов (кроме index.html)..." -ForegroundColor Cyan
    }
    $result1 = Upload-FilesParallel -Files $newFiles -BucketName $bucketName -DistPath $sourceRoot -MaxParallel $MaxParallel -Label "обычных файлов"
    Write-Host "✅ Загружено обычных файлов: $($result1.Uploaded)/$($result1.Total)" -ForegroundColor Green
    if ($result1.Failed -gt 0) {
        Write-Host "⚠️  Ошибок: $($result1.Failed)" -ForegroundColor Yellow
    }
    if ($result1.Skipped -gt 0) {
        Write-Host "⏭️  Пропущено: $($result1.Skipped)" -ForegroundColor DarkGray
    }
    Write-Host ""
} else {
    Write-Host "ℹ️  Нет обычных файлов для загрузки" -ForegroundColor Gray
    Write-Host ""
    $result1 = @{ Uploaded = 0; Failed = 0; Skipped = 0; Total = 0 }
}

# Шаг 2: Загрузка index.html файлов в последнюю очередь
if ($indexHtmlFiles.Count -gt 0) {
    if ($Force) {
        Write-Host "☁️  Шаг 2: Загрузка index.html файлов с заменой существующих (финальный шаг)..." -ForegroundColor Cyan
    } else {
        Write-Host "☁️  Шаг 2: Загрузка index.html файлов (финальный шаг)..." -ForegroundColor Cyan
    }
    $result2 = Upload-FilesParallel -Files $indexHtmlFiles -BucketName $bucketName -DistPath $sourceRoot -MaxParallel $MaxParallel -Label "index.html файлов"
    Write-Host "✅ Загружено index.html файлов: $($result2.Uploaded)/$($result2.Total)" -ForegroundColor Green
    if ($result2.Failed -gt 0) {
        Write-Host "⚠️  Ошибок: $($result2.Failed)" -ForegroundColor Yellow
    }
    if ($result2.Skipped -gt 0) {
        Write-Host "⏭️  Пропущено: $($result2.Skipped)" -ForegroundColor DarkGray
    }
    Write-Host ""
} else {
    Write-Host "ℹ️  Нет index.html файлов для загрузки" -ForegroundColor Gray
    Write-Host ""
    $result2 = @{ Uploaded = 0; Failed = 0; Skipped = 0; Total = 0 }
}

# Шаг 3: Удаление старых файлов только в папке assets (остальные не трогаем)
Write-Host "🧹 Шаг 3: Удаление старых файлов в assets..." -ForegroundColor Cyan

# Создаем набор новых файлов для сравнения (нормализованные имена)
$newFileKeys = @{}
$newFileKeysNormalized = @{}
foreach ($file in $allFiles) {
    $relativePath = $file.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/')
    $newFileKeys[$relativePath] = $true
    # Также сохраняем нормализованное имя для сравнения
    $normalizedPath = Normalize-FileName -FileName $relativePath
    $newFileKeysNormalized[$normalizedPath] = $relativePath
}

# Находим файлы для удаления
# Сравниваем как по оригинальным, так и по нормализованным именам
$filesToDelete = @{}
foreach ($originalBucketKey in $existingFiles.Keys) {
    # Получаем исправленное имя (если есть)
    $fixedKey = $fixedToOriginalMapping.GetEnumerator() | Where-Object { $_.Value -eq $originalBucketKey } | Select-Object -First 1 -ExpandProperty Key
    if (-not $fixedKey) {
        $fixedKey = Fix-BucketFileNameEncoding -FileName $originalBucketKey
        if ($fixedKey -ne $originalBucketKey) {
            $fixedToOriginalMapping[$fixedKey] = $originalBucketKey
        }
    }
    
    $normalizedKey = Normalize-FileName -FileName $fixedKey
    $shouldDelete = $true
    
    # Проверяем по оригинальному имени из bucket
    if ($newFileKeys.ContainsKey($originalBucketKey)) {
        $shouldDelete = $false
    }
    
    # Проверяем по исправленному имени
    if ($shouldDelete -and $fixedKey -ne $originalBucketKey -and $newFileKeys.ContainsKey($fixedKey)) {
        $shouldDelete = $false
    }
    
    # Проверяем по нормализованному имени (для корректной работы с кириллицей)
    if ($shouldDelete -and $newFileKeysNormalized.ContainsKey($normalizedKey)) {
        $shouldDelete = $false
    }
    
    if ($shouldDelete) {
        # Удаляем только файлы из папки assets, остальные не трогаем
        if ($originalBucketKey -like 'assets/*') {
            $filesToDelete[$originalBucketKey] = $true
        }
    }
}

# Преобразуем в массив
$filesToDeleteArray = @($filesToDelete.Keys)

if ($filesToDeleteArray.Count -gt 0) {
    Write-Host "🗑️  Найдено старых файлов для удаления: $($filesToDeleteArray.Count)" -ForegroundColor Cyan
    $deleteResult = Delete-FilesParallel -FileKeys $filesToDeleteArray -BucketName $bucketName -MaxParallel $MaxParallel
    Write-Host "✅ Удалено старых файлов: $($deleteResult.Deleted)/$($deleteResult.Total)" -ForegroundColor Green
    if ($deleteResult.Failed -gt 0) {
        Write-Host "⚠️  Ошибок при удалении: $($deleteResult.Failed)" -ForegroundColor Yellow
    }
} else {
    Write-Host "ℹ️  Старых файлов для удаления не найдено" -ForegroundColor Gray
}

Write-Host ""

# Финальная статистика
$totalUploaded = $result1.Uploaded + $result2.Uploaded
$totalFailed = $result1.Failed + $result2.Failed
$totalSkipped = $result1.Skipped + $result2.Skipped
$totalToUpload = $filesToUpload

if ($totalFailed -eq 0 -and $totalUploaded -eq $totalToUpload) {
    Write-Host "✅ Все файлы загружены успешно! ($totalUploaded/$totalToUpload)" -ForegroundColor Green
} elseif ($totalFailed -eq 0) {
    Write-Host "✅ Загружено: $totalUploaded/$totalToUpload" -ForegroundColor Green
    if ($totalSkipped -gt 0) {
        Write-Host "⏭️  Пропущено: $totalSkipped" -ForegroundColor DarkGray
    }
} else {
    Write-Host "⚠️  Загружено: $totalUploaded/$totalToUpload" -ForegroundColor Yellow
    Write-Host "❌ Ошибок: $totalFailed" -ForegroundColor Red
    if ($totalSkipped -gt 0) {
        Write-Host "⏭️  Пропущено: $totalSkipped" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "✅ Бесшовный деплой завершен успешно!" -ForegroundColor Green
Write-Host "🌐 Ваш сайт доступен по адресу: https://$bucketName.website.yandexcloud.net" -ForegroundColor Green
