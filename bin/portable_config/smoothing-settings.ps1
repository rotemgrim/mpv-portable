<#
  Motion smoothing settings window for the portable mpv.

  Opened by scripts/smoothing_settings.lua (Ctrl+G) with the name of mpv's
  JSON IPC pipe. Settings live in vs_config.conf; changes are written there and
  the playing video is updated straight away.
#>
param([Parameter(Mandatory = $true)][string]$Pipe)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# One window per player
$created = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\smoothing-settings-$Pipe", [ref]$created)
if (-not $created) { exit }

$configPath = Join-Path $PSScriptRoot 'vs_config.conf'
$arrow = [char]0x2192
$dot = [char]0xB7
$brushes = New-Object System.Windows.Media.BrushConverter
$grey, $green, $amber = '#5F6368', '#34A853', '#F9AB00' | ForEach-Object { $brushes.ConvertFromString($_) }

# --- mpv IPC --------------------------------------------------------------

$client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Pipe, [System.IO.Pipes.PipeDirection]::InOut)
$client.Connect(3000)
$reader = New-Object System.IO.StreamReader($client)
$writer = New-Object System.IO.StreamWriter($client)
$writer.AutoFlush = $true
$script:requestId = 0

function Invoke-Mpv([object[]]$Command) {
    $script:requestId++
    $writer.WriteLine((@{ command = $Command; request_id = $script:requestId } | ConvertTo-Json -Compress))
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line) { throw 'mpv closed' }
        $msg = $line | ConvertFrom-Json
        # Skip events mpv sends on its own
        if ($msg.PSObject.Properties['request_id'] -and $msg.request_id -eq $script:requestId) { return $msg }
    }
}

function Get-MpvProperty([string]$Name) {
    $r = Invoke-Mpv @('get_property', $Name)
    if ($r.error -eq 'success') { return $r.data }
    return $null
}

# --- vs_config.conf ---------------------------------------------------------

function Read-Config {
    $values = @{}
    foreach ($line in Get-Content $configPath) {
        if ($line -match '^\s*([\w]+)\s*=\s*(.*?)\s*$') { $values[$Matches[1]] = $Matches[2] }
    }
    return $values
}

function Set-Config([hashtable]$Values) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.AddRange([string[]](Get-Content $configPath))
    foreach ($key in $Values.Keys) {
        $entry = "$key=$($Values[$key])"
        $index = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^\s*$key\s*=") { $index = $i; break }
        }
        if ($index -ge 0) { $lines[$index] = $entry } else { $lines.Add($entry) }
    }
    [System.IO.File]::WriteAllLines($configPath, $lines)
}

# --- window -----------------------------------------------------------------

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Motion smoothing" Width="460" SizeToContent="Height" ResizeMode="NoResize"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13" Foreground="#E8E8E8">
  <Window.Resources>
    <Style x:Key="Chip" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#E8E8E8"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" CornerRadius="14" Padding="14,6" Background="#2E2F33" BorderBrush="#3C3D42" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#3A3B40"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="#3D7EFF"/>
                <Setter TargetName="b" Property="BorderBrush" Value="#3D7EFF"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E8E8E8"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Background="Transparent">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <ContentPresenter VerticalAlignment="Center"/>
              <Border x:Name="track" Grid.Column="1" Width="38" Height="20" CornerRadius="10" Background="#4A4B50" Margin="12,0,0,0">
                <Ellipse x:Name="thumb" Width="14" Height="14" Fill="White" HorizontalAlignment="Left" Margin="3,0"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#3D7EFF"/>
                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#9AA0A6"/>
      <Setter Property="Margin" Value="0,14,0,6"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#9AA0A6"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
  </Window.Resources>

  <Border CornerRadius="12" Background="#1F2023" BorderBrush="#34353A" BorderThickness="1" Padding="22,16,22,18">
    <StackPanel>
      <Grid x:Name="TitleBar" Background="Transparent" Margin="0,0,0,4">
        <TextBlock Text="Motion smoothing" FontSize="17" FontWeight="SemiBold" Foreground="White" VerticalAlignment="Center"/>
        <Button x:Name="CloseButton" Content="&#x2715;" HorizontalAlignment="Right" Width="28" Height="28" Cursor="Hand"
                Foreground="#9AA0A6" Background="Transparent" BorderThickness="0" FontSize="13"/>
      </Grid>

      <TextBlock Text="MODE" Style="{StaticResource Label}"/>
      <WrapPanel>
        <RadioButton x:Name="ModeOff"   GroupName="mode" Style="{StaticResource Chip}" Content="Off"          Tag="Ctrl+1"/>
        <RadioButton x:Name="ModeBasic" GroupName="mode" Style="{StaticResource Chip}" Content="Basic"        Tag="Ctrl+2"/>
        <RadioButton x:Name="ModeFilm"  GroupName="mode" Style="{StaticResource Chip}" Content="Films &amp; TV" Tag="Ctrl+8"/>
        <RadioButton x:Name="ModeAnime" GroupName="mode" Style="{StaticResource Chip}" Content="Anime"        Tag="Ctrl+9"/>
      </WrapPanel>
      <TextBlock x:Name="ModeHint" Style="{StaticResource Hint}"/>

      <TextBlock Text="SMOOTHNESS" Style="{StaticResource Label}"/>
      <WrapPanel>
        <RadioButton x:Name="FpsAuto"  GroupName="fps" Style="{StaticResource Chip}" Content="Match screen" Tag="auto|120"/>
        <RadioButton x:Name="FpsAuto2" GroupName="fps" Style="{StaticResource Chip}" Content="Match, no limit" Tag="auto|240"/>
        <RadioButton x:Name="Fps60"    GroupName="fps" Style="{StaticResource Chip}" Content="60 fps" Tag="60|120"/>
        <RadioButton x:Name="Fps120"   GroupName="fps" Style="{StaticResource Chip}" Content="120 fps" Tag="120|120"/>
      </WrapPanel>
      <TextBlock x:Name="FpsHint" Style="{StaticResource Hint}"/>

      <TextBlock Text="LOOK" Style="{StaticResource Label}"/>
      <WrapPanel>
        <RadioButton x:Name="LookSmooth"  GroupName="look" Style="{StaticResource Chip}" Content="Smooth"  Tag="1.0"/>
        <RadioButton x:Name="LookNatural" GroupName="look" Style="{StaticResource Chip}" Content="Natural" Tag="0.6"/>
      </WrapPanel>
      <TextBlock x:Name="LookHint" Style="{StaticResource Hint}"/>

      <TextBlock Text="QUALITY" Style="{StaticResource Label}"/>
      <WrapPanel>
        <RadioButton x:Name="QualityBest" GroupName="quality" Style="{StaticResource Chip}" Content="Best" Tag="2"/>
        <RadioButton x:Name="QualityFast" GroupName="quality" Style="{StaticResource Chip}" Content="Fast" Tag="1"/>
      </WrapPanel>
      <TextBlock x:Name="QualityHint" Style="{StaticResource Hint}"/>

      <TextBlock Text="EXTRAS" Style="{StaticResource Label}"/>
      <CheckBox x:Name="SharpCuts" Style="{StaticResource Switch}">
        <StackPanel>
          <TextBlock Text="Keep scene cuts sharp"/>
          <TextBlock Style="{StaticResource Hint}" Text="Show the real frame at a cut instead of a cross-fade"/>
        </StackPanel>
      </CheckBox>
      <CheckBox x:Name="HeldFrames" Style="{StaticResource Switch}">
        <StackPanel>
          <TextBlock Text="Smooth animation held frames"/>
          <TextBlock Style="{StaticResource Hint}" Text="Cartoons drawn on twos move evenly instead of stepping"/>
        </StackPanel>
      </CheckBox>
      <CheckBox x:Name="Bars" Style="{StaticResource Switch}">
        <StackPanel>
          <TextBlock Text="Keep black bars still"/>
          <TextBlock Style="{StaticResource Hint}" Text="Letterbox bars stay black, edges next to them stay clean"/>
        </StackPanel>
      </CheckBox>
      <CheckBox x:Name="Fades" Style="{StaticResource Switch}">
        <StackPanel>
          <TextBlock Text="Follow fades"/>
          <TextBlock Style="{StaticResource Hint}" Text="Motion keeps tracking while the picture fades in or out"/>
        </StackPanel>
      </CheckBox>

      <Border CornerRadius="8" Background="#2A2B2F" Padding="12,9" Margin="0,8,0,0">
        <StackPanel Orientation="Horizontal">
          <Ellipse x:Name="StatusDot" Width="9" Height="9" Fill="#5F6368" Margin="0,0,9,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="Status" Text="Connecting..." VerticalAlignment="Center"/>
        </StackPanel>
      </Border>
    </StackPanel>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($name in 'TitleBar', 'CloseButton', 'ModeOff', 'ModeBasic', 'ModeFilm', 'ModeAnime', 'ModeHint',
                  'FpsAuto', 'FpsAuto2', 'Fps60', 'Fps120', 'FpsHint', 'LookSmooth', 'LookNatural', 'LookHint',
                  'QualityBest', 'QualityFast', 'QualityHint',
                  'SharpCuts', 'HeldFrames', 'Bars', 'Fades', 'StatusDot', 'Status') {
    $ui[$name] = $window.FindName($name)
}

$modeHints = @{
    ModeOff   = 'No smoothing: frames play as they were filmed.'
    ModeBasic = "mpv's own smoothing: removes judder, no new in-between frames. Lightest."
    ModeFilm  = 'Builds new in-between frames on the GPU. Best for films, TV and games.'
    ModeAnime = 'Same, tuned for cartoons and anime: keeps lines steady in flat colour.'
}
$lookHints = @{
    LookSmooth  = 'Every in-between frame is built: the most fluid motion.'
    LookNatural = "Real frames stay on screen longer: about half the smoothing, closer to the film's own feel."
}
$qualityHints = @{
    QualityBest = 'Cleanest edges around moving objects.'
    QualityFast = 'About half the GPU work, slightly softer edges. For slower GPUs or 4K at high frame rates.'
}

$script:loading = $true

function Get-ActiveMode {
    $vf = Get-MpvProperty 'vf'
    foreach ($f in @($vf)) {
        if ($f.name -eq 'vapoursynth') {
            $file = [string]$f.params.file
            if ($file -match 'gpumv_anime\.vpy') { return 'ModeAnime' }
            if ($file -match 'gpumv\.vpy') { return 'ModeFilm' }
            return 'Other'
        }
    }
    if ((Get-MpvProperty 'interpolation') -eq $true) { return 'ModeBasic' }
    return 'ModeOff'
}

function Update-Hints {
    foreach ($m in 'ModeOff', 'ModeBasic', 'ModeFilm', 'ModeAnime') {
        if ($ui[$m].IsChecked) { $ui.ModeHint.Text = $modeHints[$m] }
    }
    if ($ui.LookSmooth.IsChecked) { $ui.LookHint.Text = $lookHints.LookSmooth }
    if ($ui.LookNatural.IsChecked) { $ui.LookHint.Text = $lookHints.LookNatural }
    if ($ui.QualityBest.IsChecked) { $ui.QualityHint.Text = $qualityHints.QualityBest }
    if ($ui.QualityFast.IsChecked) { $ui.QualityHint.Text = $qualityHints.QualityFast }
    $screen = Get-MpvProperty 'display-fps'
    $hz = if ($screen) { [math]::Round([double]$screen) } else { $null }
    $ui.FpsHint.Text = if ($ui.FpsAuto.IsChecked -or $ui.FpsAuto2.IsChecked) {
        $limit = if ($ui.FpsAuto.IsChecked) { ' (at most 120 fps)' } else { ', even above 120 Hz' }
        if ($hz) { "Your screen runs at $hz Hz; smoothing follows it$limit." } else { "Smoothing follows your screen$limit." }
    } else { "A fixed $(if ($ui.Fps60.IsChecked) { 60 } else { 120 }) fps, whatever the screen." }
}

function Load-State {
    $script:loading = $true
    $c = Read-Config
    $mode = Get-ActiveMode
    if ($ui.ContainsKey($mode)) { $ui[$mode].IsChecked = $true }
    $dst = if ($c['dst_fps']) { $c['dst_fps'] } else { 'auto' }
    $max = if ($c['max_fps']) { [int]$c['max_fps'] } else { 120 }
    if ($dst -eq 'auto') { if ($max -gt 120) { $ui.FpsAuto2.IsChecked = $true } else { $ui.FpsAuto.IsChecked = $true } }
    elseif ($dst -eq '60') { $ui.Fps60.IsChecked = $true }
    elseif ($dst -eq '120') { $ui.Fps120.IsChecked = $true }
    if ($c['gpumv_mode'] -eq '1') { $ui.QualityFast.IsChecked = $true } else { $ui.QualityBest.IsChecked = $true }
    if ($c['gpumv_strength'] -and [double]$c['gpumv_strength'] -lt 0.99) { $ui.LookNatural.IsChecked = $true } else { $ui.LookSmooth.IsChecked = $true }
    $ui.SharpCuts.IsChecked = $c['gpumv_blend'] -ne '1'
    $ui.HeldFrames.IsChecked = $c['gpumv_dedup'] -ne '0'
    $ui.Bars.IsChecked = $c['gpumv_bars'] -ne '0'
    $ui.Fades.IsChecked = $c['gpumv_fades'] -ne '0'
    Update-Hints
    $script:loading = $false
}

# Settings take effect on the playing video at once
function Save-And-Reload([hashtable]$Values) {
    if ($script:loading) { return }
    Set-Config $Values
    Invoke-Mpv @('script-message', 'vs-reload') | Out-Null
    Update-Hints
}

foreach ($m in 'ModeOff', 'ModeBasic', 'ModeFilm', 'ModeAnime') {
    $ui[$m].Add_Checked({
        param($sender)
        if ($script:loading) { return }
        Invoke-Mpv @('keypress', [string]$sender.Tag) | Out-Null
        Update-Hints
    })
}
foreach ($f in 'FpsAuto', 'FpsAuto2', 'Fps60', 'Fps120') {
    $ui[$f].Add_Checked({
        param($sender)
        $parts = ([string]$sender.Tag).Split('|')
        Save-And-Reload @{ dst_fps = $parts[0]; max_fps = $parts[1] }
    })
}
foreach ($l in 'LookSmooth', 'LookNatural') {
    $ui[$l].Add_Checked({ param($sender) Save-And-Reload @{ gpumv_strength = [string]$sender.Tag } })
}
foreach ($q in 'QualityBest', 'QualityFast') {
    $ui[$q].Add_Checked({ param($sender) Save-And-Reload @{ gpumv_mode = [string]$sender.Tag } })
}
# Each switch's Tag: setting|value when on|value when off
$ui.SharpCuts.Tag = 'gpumv_blend|0|1'
$ui.HeldFrames.Tag = 'gpumv_dedup|1|0'
$ui.Bars.Tag = 'gpumv_bars|1|0'
$ui.Fades.Tag = 'gpumv_fades|1|0'
foreach ($s in 'SharpCuts', 'HeldFrames', 'Bars', 'Fades') {
    $ui[$s].Add_Checked({ param($sender) $k = ([string]$sender.Tag).Split('|'); Save-And-Reload @{ $k[0] = $k[1] } })
    $ui[$s].Add_Unchecked({ param($sender) $k = ([string]$sender.Tag).Split('|'); Save-And-Reload @{ $k[0] = $k[2] } })
}

$ui.CloseButton.Add_Click({ $window.Close() })
$ui.TitleBar.Add_MouseLeftButtonDown({ $window.DragMove() })
$window.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $window.Close() } })

# Status line, once a second. Dropped frames count over the last 10 seconds:
# mpv's counter runs from the start of the file, switching modes included
$script:dropHistory = New-Object System.Collections.Generic.Queue[int]
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    try {
        $mode = Get-ActiveMode
        if ($mode -ne 'Other' -and -not $ui[$mode].IsChecked) { Load-State }
        $out = Get-MpvProperty 'estimated-vf-fps'
        $src = Get-MpvProperty 'container-fps'
        $drops = Get-MpvProperty 'frame-drop-count'
        $names = @{ ModeOff = 'Off'; ModeBasic = 'Basic'; ModeFilm = 'Films & TV'; ModeAnime = 'Anime'; Other = 'Other mode' }
        $parts = @($names[$mode])
        if ($out) {
            $rate = if ($src) { '{0:0.###} {1} {2:0.###} fps' -f [double]$src, $arrow, [double]$out } else { '{0:0.###} fps' -f [double]$out }
            $parts += $rate
        }
        $recent = 0
        if ($null -ne $drops) {
            # mpv restarts the count when the filter restarts (a mode or setting change)
            if ($script:dropHistory.Count -and [int]$drops -lt @($script:dropHistory)[-1]) { $script:dropHistory.Clear() }
            $script:dropHistory.Enqueue([int]$drops)
            while ($script:dropHistory.Count -gt 11) { [void]$script:dropHistory.Dequeue() }
            $recent = [int]$drops - $script:dropHistory.Peek()
            $parts += $(if ($recent -eq 0) { 'smooth, no dropped frames' } else { "$recent dropped frames in 10 s" })
        }
        $ui.Status.Text = $parts -join " $dot "
        $ui.StatusDot.Fill = if ($mode -in 'ModeFilm', 'ModeAnime', 'Other') {
            if ($recent -gt 0) { $amber } else { $green }
        } else { $grey }
    } catch {
        $window.Close()  # mpv was closed
    }
})

Load-State
$timer.Start()
$window.ShowDialog() | Out-Null
$timer.Stop()
$client.Dispose()
$mutex.ReleaseMutex()
