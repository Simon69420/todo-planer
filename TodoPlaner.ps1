Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing, System.Windows.Forms

# Win32-Helfer: Klick-Durchlass, eigenes Taskleisten-Icon, globaler Hotkey
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace TodoPlaner {
    public static class Native {
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
        [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
        [DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);
        struct POINT { public int X; public int Y; }

        public static int[] CursorPos() { POINT p; GetCursorPos(out p); return new int[] { p.X, p.Y }; }
        public static bool LeftDown() { return (GetAsyncKeyState(1) & 0x8000) != 0; }
        public static bool IsClickThrough(IntPtr h) { return (GetWindowLong(h, -20) & 0x20) != 0; }
        public static void SetClickThrough(IntPtr h, bool on) {
            int s = GetWindowLong(h, -20);
            SetWindowLong(h, -20, on ? (s | 0x20) : (s & ~0x20));
        }
    }

    public class HotKey : NativeWindow, IDisposable {
        [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
        public event EventHandler Pressed;
        public bool Registered { get; private set; }
        public HotKey(uint mod, uint vk) {
            CreateHandle(new CreateParams());
            Registered = RegisterHotKey(Handle, 1, mod | 0x4000, vk);
        }
        protected override void WndProc(ref Message m) {
            if (m.Msg == 0x0312) { var h = Pressed; if (h != null) h(this, EventArgs.Empty); }
            base.WndProc(ref m);
        }
        public void Dispose() { UnregisterHotKey(Handle, 1); DestroyHandle(); }
    }
}
'@

# Nur eine Instanz gleichzeitig
$mutex = New-Object System.Threading.Mutex($false, 'Local\TodoPlaner_SingleInstance')
if (-not $mutex.WaitOne(0)) { exit }

# Eigene Taskleisten-Gruppe, damit dort unser Icon statt dem PowerShell-Icon erscheint
[void][TodoPlaner.Native]::SetCurrentProcessExplicitAppUserModelID('TodoPlaner')

$dataFile     = Join-Path $PSScriptRoot 'todos.json'
$settingsFile = Join-Path $PSScriptRoot 'settings.json'
$logFile      = Join-Path $PSScriptRoot 'error.log'
$leadMinutes  = 15     # so viele Minuten vor einem Outlook-Termin kommt die Erinnerung
$leadUm       = 5      # "um 13:00"  -> 5 Minuten vorher erinnern
$leadBis      = 30     # "bis 13:00" -> 30 Minuten vorher erinnern
$showAheadDays = 2     # Aufgaben mit spaeterem Datum erst so viele Tage vorher in der Liste zeigen
$aiModel      = 'qwen3.5:2b'
$aiUrl        = 'http://localhost:11434'
$ae = [char]0xE4; $ue = [char]0xFC

function Write-Log($msg) {
    try { Add-Content -Path $logFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg) -Encoding UTF8 } catch {}
}

# ---------- Icon: gruenes abgerundetes Quadrat mit weissem Haken ----------
function New-TodoBitmap([int]$s) {
    $bmp = New-Object System.Drawing.Bitmap $s, $s
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $d = [single]([math]::Max(4, $s * 0.44))
    $w = [single]($s - 1)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($w - $d, 0, $d, $d, 270, 90)
    $path.AddArc($w - $d, $w - $d, $d, $d, 0, 90)
    $path.AddArc(0, $w - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $brush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
        [System.Drawing.Point]::new(0, 0), [System.Drawing.Point]::new($s, $s),
        [System.Drawing.Color]::FromArgb(255, 0x6F, 0xCF, 0x97), [System.Drawing.Color]::FromArgb(255, 0x1F, 0x8A, 0x5B))
    $g.FillPath($brush, $path)
    $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::White, [single]($s * 0.12))
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $pts = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new($s * 0.27, $s * 0.53),
        [System.Drawing.PointF]::new($s * 0.44, $s * 0.69),
        [System.Drawing.PointF]::new($s * 0.74, $s * 0.35))
    $g.DrawLines($pen, $pts)
    $pen.Dispose(); $brush.Dispose(); $path.Dispose(); $g.Dispose()
    return $bmp
}

# ---------- Zustand laden ----------
function ConvertTo-Date($s) {
    if (-not $s) { return $null }
    try { return [datetime]::ParseExact([string]$s, 's', [cultureinfo]::InvariantCulture) } catch { return $null }
}

function New-Todo($text, [bool]$important = $false, $due = $null, [bool]$notified = $false, $source = 'manual', $end = $null, $kind = 'um') {
    @{ Id = [guid]::NewGuid().ToString(); Text = [string]$text; Important = $important; Due = $due
       Notified = $notified; Source = $source; End = $end; Kind = $kind }
}

$state = @{ Items = @(); Left = $null; Top = $null; Width = 280; Height = 360; Topmost = $true; Opacity = 0.6; SeenEvents = $null }
if (Test-Path $dataFile) {
    try {
        $loaded = Get-Content $dataFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $loaded.PSObject.Properties) { $state[$p.Name] = $p.Value }
    } catch {}
}

$todos = New-Object System.Collections.ArrayList
foreach ($t in @($state.Items)) {
    if (-not $t) { continue }
    if ($t -is [string]) { [void]$todos.Add((New-Todo $t)); continue }   # altes Format
    if (-not $t.Text) { continue }
    $src  = if ($t.Source) { [string]$t.Source } else { 'manual' }
    $kind = if ($t.Kind) { [string]$t.Kind } else { 'um' }
    $loadedItem = New-Todo $t.Text ([bool]$t.Important) (ConvertTo-Date $t.Due) ([bool]$t.Notified) $src (ConvertTo-Date $t.End) $kind
    $loadedItem.Stage = [int]$t.Stage
    if ($t.FullText) { $loadedItem.FullText = [string]$t.FullText }
    [void]$todos.Add($loadedItem)
}

# Bereits erinnerte Termine (damit nichts doppelt kommt); aeltere als 2 Tage vergessen
$script:seen = @{}
if ($state.SeenEvents) {
    foreach ($p in $state.SeenEvents.PSObject.Properties) {
        $d = ConvertTo-Date $p.Value
        if ($d -and $d -gt (Get-Date).AddDays(-2)) { $script:seen[$p.Name] = $p.Value }
    }
}

$settings = @{ CalendarEnabled = $true; AiEnabled = $true; IcsUrls = @(); CalendarIds = @() }
if (Test-Path $settingsFile) {
    try {
        $loaded = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $loaded.PSObject.Properties) { $settings[$p.Name] = $p.Value }
    } catch {}
}

$script:bgOpacity   = [double]$state.Opacity
$script:ready       = $false
$script:events      = @()
$script:calStatus   = ''
$script:editingId   = $null
$script:dragId      = $null
$script:undoStack   = New-Object System.Collections.Stack
$script:showLater   = $false
$script:hiddenCount = 0

# ---------- UI ----------
$sharedStyles = @'
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#B0FFFFFF"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="26"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#26FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
'@

$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Todo" Width="280" Height="360" MinWidth="220" MinHeight="150"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="CanResizeWithGrip" ShowInTaskbar="False"
        FontFamily="Segoe UI" FontSize="14">
  <Window.Resources>
%STYLES%
    <Style x:Key="CheckBtn" TargetType="Button">
      <Setter Property="Width" Value="18"/>
      <Setter Property="Height" Value="18"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="#AAFFFFFF"
                    BorderThickness="1.5" CornerRadius="9">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="#FF6FCF97"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="EditBox" TargetType="TextBox">
      <Setter Property="Background" Value="#26FFFFFF"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="CaretBrush" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="4,2"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style x:Key="LinkBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#90FFFFFF"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="Transparent" Padding="2,6,2,2">
              <ContentPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Foreground" Value="White"/>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Border x:Name="Root" CornerRadius="12" Background="#99181818" BorderBrush="#33FFFFFF"
          BorderThickness="1" Padding="12,8,12,14">
    <DockPanel>
      <Grid x:Name="Header" DockPanel.Dock="Top" Background="Transparent" Margin="0,0,0,6"
            ToolTip="Ziehen zum Verschieben &#183; Mausrad = Transparenz">
        <TextBlock Text="Todo" Foreground="White" FontWeight="SemiBold" FontSize="15"
                   VerticalAlignment="Center" Margin="2,0,0,0"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="UndoBtn" Style="{StaticResource IconBtn}" Content="&#xE7A7;" Visibility="Collapsed"
                  ToolTip="R&#252;ckg&#228;ngig (Strg+Z)"/>
          <Button x:Name="GearBtn" Style="{StaticResource IconBtn}" Content="&#xE713;"
                  ToolTip="Einstellungen"/>
          <Button x:Name="PinBtn" Style="{StaticResource IconBtn}" Content="&#xE718;"
                  ToolTip="Immer im Vordergrund"/>
          <Button x:Name="CloseBtn" Style="{StaticResource IconBtn}" Content="&#xE921;"
                  ToolTip="Minimieren &#8211; Taskleiste oder Strg+Alt+T holt ihn zur&#252;ck"/>
        </StackPanel>
      </Grid>

      <Border DockPanel.Dock="Bottom" Margin="0,8,8,0" CornerRadius="8" Background="#22FFFFFF">
        <Grid>
          <TextBox x:Name="InputBox" Background="Transparent" BorderThickness="0" Foreground="White"
                   CaretBrush="White" Padding="8,6" VerticalContentAlignment="Center"/>
          <TextBlock x:Name="Placeholder" Text="Neue Aufgabe + Enter" Foreground="#80FFFFFF"
                     Margin="11,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
        </Grid>
      </Border>

      <ScrollViewer x:Name="Scroll" VerticalScrollBarVisibility="Hidden" Background="Transparent" AllowDrop="True">
        <StackPanel x:Name="List"/>
      </ScrollViewer>
    </DockPanel>
  </Border>
</Window>
'@ -replace '%STYLES%', $sharedStyles

$settingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Einstellungen" Width="340" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" ShowInTaskbar="False" WindowStartupLocation="CenterOwner"
        FontFamily="Segoe UI" FontSize="13" Foreground="White">
  <Window.Resources>
%STYLES%
    <Style x:Key="Switch" TargetType="ToggleButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="track" Width="44" Height="24" CornerRadius="12" Background="#40FFFFFF">
              <Ellipse x:Name="knob" Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="3,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="#FF2E9E6A"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border CornerRadius="12" Background="#FF1C1C1C" BorderBrush="#33FFFFFF" BorderThickness="1" Padding="16,10,16,16">
    <StackPanel>
      <Grid x:Name="SHeader" Background="Transparent" Margin="0,0,0,12">
        <TextBlock Text="Einstellungen" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
        <Button x:Name="SClose" Style="{StaticResource IconBtn}" Content="&#xE711;" HorizontalAlignment="Right"/>
      </Grid>

      <DockPanel>
        <ToggleButton x:Name="CalSwitch" Style="{StaticResource Switch}" DockPanel.Dock="Right" VerticalAlignment="Center"/>
        <StackPanel Margin="0,0,12,0">
          <TextBlock Text="Kalender" FontWeight="SemiBold"/>
          <TextBlock Text="Outlook und Google zusammen. 15 Min. vor einem Termin kommt er oben auf die Liste, danach verschwindet er wieder."
                     TextWrapping="Wrap" Opacity="0.65" FontSize="12" Margin="0,2,0,0"/>
        </StackPanel>
      </DockPanel>
      <TextBlock x:Name="CalStatus" TextWrapping="Wrap" Opacity="0.65" FontSize="12" Margin="0,8,0,0"/>
      <StackPanel x:Name="CalFolders" Margin="0,4,0,0"/>

      <Border CornerRadius="8" Background="#14FFFFFF" Padding="10,4,10,8" Margin="0,8,0,0">
        <ScrollViewer x:Name="AgendaScroll" MaxHeight="230" VerticalScrollBarVisibility="Hidden">
          <StackPanel x:Name="Agenda"/>
        </ScrollViewer>
      </Border>

      <TextBlock Text="Google-Kalender dazu (optional)" FontSize="12" FontWeight="SemiBold" Margin="0,10,0,0"/>
      <TextBlock TextWrapping="Wrap" Opacity="0.65" FontSize="12" Margin="0,2,0,4"
                 Text="Google Kalender &#8594; Einstellungen &#8594; dein Kalender &#8594; &#8222;Privatadresse im iCal-Format&#8220; kopieren und hier einf&#252;gen."/>
      <Border CornerRadius="6" Background="#26FFFFFF">
        <Grid>
          <TextBox x:Name="IcsBox" Background="Transparent" BorderThickness="0" Foreground="White" CaretBrush="White"
                   Padding="6,4" FontSize="12"/>
          <TextBlock x:Name="IcsPlaceholder" Text="https://calendar.google.com/calendar/ical/..." Foreground="#60FFFFFF"
                     FontSize="12" Margin="9,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
        </Grid>
      </Border>

      <DockPanel Margin="0,16,0,0">
        <ToggleButton x:Name="AiSwitch" Style="{StaticResource Switch}" DockPanel.Dock="Right" VerticalAlignment="Center"/>
        <StackPanel Margin="0,0,12,0">
          <TextBlock Text="Tippfehler korrigieren" FontWeight="SemiBold"/>
          <TextBlock Text="Eine kleine KI auf deinem PC verbessert Schreibfehler. Nichts geht ins Internet."
                     TextWrapping="Wrap" Opacity="0.65" FontSize="12" Margin="0,2,0,0"/>
        </StackPanel>
      </DockPanel>
      <TextBlock x:Name="AiStatus" TextWrapping="Wrap" Opacity="0.65" FontSize="12" Margin="0,10,0,0"/>

      <Border Height="1" Background="#22FFFFFF" Margin="0,14,0,10"/>
      <TextBlock TextWrapping="Wrap" Opacity="0.65" FontSize="12" LineHeight="18">
        <Run FontWeight="SemiBold" Text="Tipps"/><LineBreak/>
        <Run Text="&#8226; Zeiten werden erkannt: bis 13:00, um 1300, morgen um 9, bis Freitag, in 30 min"/><LineBreak/>
        <Run Text="&#8226; &#8222;um&#8220; erinnert 5 Min. vorher, &#8222;bis&#8220; 30 Min. vorher"/><LineBreak/>
        <Run Text="&#8226; Doppelklick = bearbeiten, ziehen = sortieren, Stern = wichtig (immer sichtbar)"/><LineBreak/>
        <Run Text="&#8226; Strg+Z = r&#252;ckg&#228;ngig, Strg+Alt+T = ein-/ausblenden"/>
      </TextBlock>
    </StackPanel>
  </Border>
</Window>
'@ -replace '%STYLES%', $sharedStyles

$window      = [Windows.Markup.XamlReader]::Parse($mainXaml)
$root        = $window.FindName('Root')
$header      = $window.FindName('Header')
$undoBtn     = $window.FindName('UndoBtn')
$gearBtn     = $window.FindName('GearBtn')
$pinBtn      = $window.FindName('PinBtn')
$closeBtn    = $window.FindName('CloseBtn')
$inputBox    = $window.FindName('InputBox')
$placeholder = $window.FindName('Placeholder')
$scroll      = $window.FindName('Scroll')
$list        = $window.FindName('List')
$checkStyle  = $window.FindResource('CheckBtn')
$iconStyle   = $window.FindResource('IconBtn')
$editStyle   = $window.FindResource('EditBox')
$linkStyle   = $window.FindResource('LinkBtn')
$iconFont    = New-Object System.Windows.Media.FontFamily 'Segoe MDL2 Assets'

function New-Brush([byte]$a, [byte]$r, [byte]$g, [byte]$b) {
    New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($a, $r, $g, $b))
}
$doneBrush    = New-Brush 0xFF 0x6F 0xCF 0x97
$textBrush    = New-Brush 0xEE 0xFF 0xFF 0xFF
$goldBrush    = New-Brush 0xFF 0xFF 0xCC 0x66
$mutedBrush   = New-Brush 0x99 0xFF 0xFF 0xFF
$faintBrush   = New-Brush 0x40 0xFF 0xFF 0xFF
$overdueBrush = New-Brush 0xFF 0xFF 0x8A 0x80
$outlookBrush = New-Brush 0xFF 0x4A 0x90 0xE2
$googleBrush  = New-Brush 0xFF 0x34 0xA8 0x53

# ---------- Speichern ----------
function Save-State {
    if (-not $script:ready) { return }
    $obj = [ordered]@{
        Items = @($todos | ForEach-Object {
            [ordered]@{
                Text      = $_.Text
                Important = [bool]$_.Important
                Due       = if ($_.Due) { $_.Due.ToString('s') } else { $null }
                End       = if ($_.End) { $_.End.ToString('s') } else { $null }
                Notified  = [bool]$_.Notified
                Source    = $_.Source
                Kind      = $_.Kind
                Stage     = [int]$_.Stage
                FullText  = $_.FullText
            }
        })
        Left       = $window.Left
        Top        = $window.Top
        Width      = $window.Width
        Height     = $window.Height
        Topmost    = $window.Topmost
        Opacity    = $script:bgOpacity
        SeenEvents = $script:seen
    }
    try { $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $dataFile -Encoding UTF8 } catch {}
}

function Save-Settings {
    try { $settings | ConvertTo-Json | Set-Content -Path $settingsFile -Encoding UTF8 } catch {}
}

# ---------- Zeit-Erkennung ----------
# Versteht z.B.: "bis 13:00", "um 1300", "bis 17 Uhr", "morgen um 9", "bis Freitag", "am Montag um 10",
# "bis 24.12.", "Meeting 10:30", "in 30 min", "@14:30". "um" = Zeitpunkt, "bis" = Deadline.
$dayPattern = '(?:(?:\u00fc|ue)bermorgen|heute|morgen|(?:am\s+)?(?:montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag)|\d{1,2}\.\d{1,2}\.(?:\d{2,4})?)'
$weekdays = @{ montag = 1; dienstag = 2; mittwoch = 3; donnerstag = 4; freitag = 5; samstag = 6; sonntag = 0 }

function Resolve-Day([string]$day) {
    $today = (Get-Date).Date
    $d = ($day.ToLower() -replace '^am\s+', '').Trim()
    if ($d -eq 'heute') { return $today }
    if ($d -eq 'morgen') { return $today.AddDays(1) }
    if ($d -match 'bermorgen$') { return $today.AddDays(2) }
    if ($weekdays.ContainsKey($d)) { return $today.AddDays(($weekdays[$d] - [int]$today.DayOfWeek + 7) % 7) }
    if ($d -match '^(\d{1,2})\.(\d{1,2})\.(\d{2,4})?$') {
        $hasYear = [bool]$Matches[3]
        $y = if ($hasYear) { [int]$Matches[3] } else { $today.Year }
        if ($y -lt 100) { $y += 2000 }
        $r = $null
        try { $r = [datetime]::new($y, [int]$Matches[2], [int]$Matches[1]) } catch { return $null }
        if (-not $hasYear -and $r -lt $today) { $r = $r.AddYears(1) }
        return $r
    }
    return $null
}

function Convert-TimeToken([string]$t) {
    if ($t -match '^(\d{1,2})[:.](\d{2})$') { $h = [int]$Matches[1]; $m = [int]$Matches[2] }
    elseif ($t -match '^(\d{1,2})(\d{2})$') { $h = [int]$Matches[1]; $m = [int]$Matches[2] }   # 1300, 930
    elseif ($t -match '^\d{1,2}$') { $h = [int]$t; $m = 0 }
    else { return $null }
    if ($h -ge 1 -and $h -le 6) { $h += 12 }   # "um 3" meint im Alltag 15 Uhr
    if ($h -gt 23 -or $m -gt 59) { return $null }
    return [timespan]::new($h, $m, 0)
}

function Remove-Match([string]$s, $m) {
    (($s.Remove($m.Index, $m.Length) -replace '\s{2,}', ' ') -replace '\s+([,;!?])', '$1').Trim(' ', ',', ';', '-')
}

function Get-TimeInfo([string]$s) {
    $now  = Get-Date
    $opt  = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $end  = '(?=$|\s|[,;!?])'
    $kw   = '(?<kw>(?:um|gegen|bis|bsi|sp(?:\u00e4|ae)testens)\s+|@\s*)'
    $time = '(?<t>\d{1,2}[:.]\d{2}|\d{3,4}|\d{1,2})(?:\s*(?:uhr|h)\b)?'
    $kind = 'um'; $day = $null; $tod = $null; $due = $null

    $m = [regex]::Match($s, "(?:^|\s)$kw(?:(?<day>$dayPattern)\s+(?:um\s+)?)?$time$end", $opt)
    if (-not $m.Success) {
        # ohne Schluesselwort nur eindeutige Uhrzeiten: 13:00 oder 13 Uhr
        $m = [regex]::Match($s, "(?:^|\s)(?:(?<day>$dayPattern)\s+)?(?:um\s+)?(?<t>\d{1,2}:\d{2}|\d{1,2}(?=\s*(?:uhr|h)\b))(?:\s*(?:uhr|h)\b)?$end", $opt)
    }
    if ($m.Success) {
        $tod = Convert-TimeToken $m.Groups['t'].Value
        if ($tod) {
            if ($m.Groups['kw'].Value -match '^(bis|bsi|sp)') { $kind = 'bis' }
            if ($m.Groups['day'].Success) { $day = Resolve-Day $m.Groups['day'].Value }
            $s = Remove-Match $s $m
        }
    }

    if (-not $tod) {
        # relativ: "in 30 min", "@2h"
        $m = [regex]::Match($s, "(?:^|\s)(?:in|@)\s*(?<n>\d+)\s*(?<u>minuten|min|m|stunden|stunde|std|h)$end", $opt)
        if ($m.Success) {
            $n = [int]$m.Groups['n'].Value
            $due = if ($m.Groups['u'].Value -match '^(h|std|stunde)') { $now.AddHours($n) } else { $now.AddMinutes($n) }
            return @{ Text = (Remove-Match $s $m); Due = $due; Kind = 'um' }
        }
        # nur Tag als Deadline: "bis Freitag", "bis morgen"
        $m = [regex]::Match($s, "(?:^|\s)(?<kw>bis|bsi)\s+(?<day>$dayPattern)$end", $opt)
        if ($m.Success) {
            $day = Resolve-Day $m.Groups['day'].Value
            if ($day) {
                $due = $day.AddHours(9)
                if ($due -le $now) { $due = $day.AddHours(17) }
                if ($due -le $now) { $due = $null }
                if ($due) { return @{ Text = (Remove-Match $s $m); Due = $due; Kind = 'bis' } }
            }
        }
        return @{ Text = $s.Trim(); Due = $null; Kind = 'um' }
    }

    # Tag steht woanders im Text ("Zahnarzt morgen um 9" / "um 9 morgen")
    if (-not $day) {
        $m = [regex]::Match($s, "(?:^|\s)(?<day>$dayPattern)$end", $opt)
        if ($m.Success) {
            $day = Resolve-Day $m.Groups['day'].Value
            if ($day) { $s = Remove-Match $s $m }
        }
    }
    if ($day) { $due = $day.Add($tod) }
    else {
        $due = $now.Date.Add($tod)
        if ($due -le $now) { $due = $due.AddDays(1) }
    }
    @{ Text = $s.Trim(); Due = $due; Kind = $kind }
}

# Minuten vor dem Zeitpunkt, zu denen erinnert wird. Anmeldungen (LPIS usw.) zweimal: 30 und 5 Min. vorher
function Get-Leads($item) {
    if ($item.Text -match 'anmeld') { return @(30, 5) }
    if ($item.Kind -eq 'bis') { return @($leadBis) }
    return @($leadUm)
}

function Format-Due([datetime]$d) {
    $today = (Get-Date).Date
    if ($d.Date -eq $today) { return $d.ToString('HH:mm') }
    if ($d.Date -eq $today.AddDays(1)) { return 'morgen ' + $d.ToString('HH:mm') }
    return $d.ToString('ddd dd.MM. HH:mm')
}

function Format-EditText($item) {
    $text = if ($item.FullText) { $item.FullText } else { $item.Text }   # beim Bearbeiten immer den vollen Text
    if (-not $item.Due -or $item.Source -eq 'calendar') { return $text }
    $today = (Get-Date).Date
    $k = if ($item.Kind -eq 'bis') { 'bis' } else { 'um' }
    if ($item.Due.Date -eq $today) { return '{0} {1} {2:HH:mm}' -f $text, $k, $item.Due }
    if ($item.Due.Date -eq $today.AddDays(1)) { return '{0} {1} morgen {2:HH:mm}' -f $text, $k, $item.Due }
    return '{0} {1} {2:dd.MM.yyyy} {2:HH:mm}' -f $text, $k, $item.Due
}

# ---------- KI-Korrektur (lokales Ollama-Modell) ----------
# Das Modell liefert einen Vorschlag; uebernommen werden nur kleine Tippfehler-Korrekturen pro Wort.
function Get-EditDistance([string]$a, [string]$b) {
    $w = $b.Length + 1
    $d = New-Object 'int[]' (($a.Length + 1) * $w)
    for ($i = 0; $i -le $a.Length; $i++) { $d[$i * $w] = $i }
    for ($j = 0; $j -le $b.Length; $j++) { $d[$j] = $j }
    for ($i = 1; $i -le $a.Length; $i++) {
        for ($j = 1; $j -le $b.Length; $j++) {
            $cost = if ($a[$i - 1] -ceq $b[$j - 1]) { 0 } else { 1 }
            $del  = $d[($i - 1) * $w + $j] + 1
            $ins  = $d[$i * $w + $j - 1] + 1
            $sub  = $d[($i - 1) * $w + $j - 1] + $cost
            $d[$i * $w + $j] = [math]::Min([math]::Min($del, $ins), $sub)
        }
    }
    $d[$a.Length * $w + $b.Length]
}

function Merge-Correction([string]$orig, [string]$fixed) {
    $o = @($orig.Trim() -split '\s+')
    $f = @($fixed.Trim() -split '\s+')
    if ($f.Count -lt $o.Count -or $f.Count -gt $o.Count + 2) { return $orig }   # Modell hat umformuliert -> verwerfen
    $j = 0
    $out = for ($i = 0; $i -lt $o.Count; $i++) {
        $a = $o[$i]
        if ($j -ge $f.Count) { $a; continue }
        $b = $f[$j]; $j++
        # getrennt geschrieben? ("fertigmachn" -> "fertig machen")
        if ($j -lt $f.Count -and ($f.Count - $j) -gt ($o.Count - $i - 1)) {
            if ((Get-EditDistance $a.ToLower() ($b + $f[$j]).ToLower()) -lt (Get-EditDistance $a.ToLower() $b.ToLower())) {
                $b = $b + ' ' + $f[$j]; $j++
            }
        }
        if ($a -ceq $b) { $a; continue }
        # Zahlen, ganz kurze Woerter, "bsi" (= bis) und Abkuerzungen/Namen mit Grossbuchstaben im Wort nie anfassen
        if ($a.Length -le 2 -or $a -eq 'bsi' -or $a -match '\d' -or $a -cmatch '^.+[A-Z]') { $a; continue }
        if ($a -ieq $b) {
            # nur Gross-/Kleinschreibung: klein -> gross (Nomen) erlauben, gross -> klein nicht
            if ($a -cmatch '^[a-z\u00e4\u00f6\u00fc]' -and $b -cmatch '^[A-Z\u00c4\u00d6\u00dc]') { $b } else { $a }
            continue
        }
        $limit = if ($a.Length -le 3) { 1 } else { [math]::Max(1, [math]::Floor($a.Length / 3)) }
        if ((Get-EditDistance $a.ToLower() ($b -replace ' ', '').ToLower()) -le $limit) { $b } else { $a }
    }
    if ($j -ne $f.Count) { return $orig }   # Modell hat Woerter hinzugefuegt
    $out -join ' '
}

$aiPrompt = @'
Du bekommst einen Todo-Eintrag. Antworte mit JSON mit zwei Feldern:
"text": der Eintrag mit korrigierten Tippfehlern. Sonst exakt unveraendert (keine Umformulierung, Namen/Zahlen/Abkuerzungen bleiben).
"short": eine knappe Version fuer eine Todo-Liste mit 3 bis 7 Woertern, als normale Woerter mit Leerzeichen (keine Bindestrich-Ketten).
Behalte immer: die Taetigkeit (z.B. Anmeldung, schicken, abgeben), Namen, Nummern und Daten/Fristen (z.B. 2.11.).
Lass Fuellwoerter, Begruendungen, Hoeflichkeiten und Werbung weg.
'@

$shortenFrom = 45   # ab so vielen Zeichen wird ein Eintrag gekuerzt angezeigt (Volltext im Tooltip)

# Prueft die Kurzfassung der KI: Daten/Nummern und "Anmeldung" muessen bleiben, nichts erfinden
function Test-ShortOk([string]$orig, [string]$short) {
    if (-not $short -or $short.Length -ge $orig.Length * 0.8) { return $false }
    foreach ($m in [regex]::Matches($orig, '\d{1,2}\.\d{1,2}\.(?:\d{2,4})?|\d{3,}')) {
        if ($short -notmatch [regex]::Escape($m.Value.TrimEnd('.'))) { return $false }
    }
    if ($orig -match 'anmeld' -and $short -notmatch 'anmeld') { return $false }
    $origWords = @([regex]::Matches($orig.ToLower(), '[\p{L}\d]+') | ForEach-Object { $_.Value })
    $unmatched = 0
    foreach ($w in [regex]::Matches($short, '[\p{L}\d]+')) {
        $t = $w.Value; $tl = $t.ToLower(); $found = $false
        foreach ($ow in $origWords) {
            $n = [math]::Min(5, [math]::Min($ow.Length, $tl.Length))
            if ($ow -eq $tl -or ($n -ge 4 -and $ow.Substring(0, $n) -eq $tl.Substring(0, $n))) { $found = $true; break }
        }
        if ($found) { continue }
        if ($t -cmatch '^[A-Z\d]{2,}$') { return $false }   # erfundene Abkuerzung
        if ($t.Length -ge 4) { $unmatched++ }
    }
    return $unmatched -le 1
}

$aiScript = @'
param($text, $model, $prompt, $url)
$body = @{
    model = $model; stream = $false; think = $false; keep_alive = '30m'
    format = @{ type = 'object'; properties = @{ text = @{ type = 'string' }; short = @{ type = 'string' } }; required = @('text', 'short') }
    options = @{ temperature = 0 }
    messages = @(@{ role = 'system'; content = $prompt }, @{ role = 'user'; content = $text })
} | ConvertTo-Json -Depth 6
$r = Invoke-RestMethod "$url/api/chat" -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 90
$r.message.content | ConvertFrom-Json
'@

$script:aiJobs = New-Object System.Collections.ArrayList
$script:aiStatus = $null
$script:lastWarm = [datetime]::MinValue
$script:warmJob = $null

function Start-AiCorrection($id, [string]$text) {
    if (-not $settings.AiEnabled) { return }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($aiScript).AddArgument($text).AddArgument($aiModel).AddArgument($aiPrompt).AddArgument($aiUrl)
    [void]$script:aiJobs.Add(@{ Id = $id; Orig = $text; PS = $ps; Handle = $ps.BeginInvoke() })
    $aiTimer.Start()
}

# Modell schon beim Tippen in den Speicher laden, damit die Korrektur flott kommt
function Start-AiWarmup {
    if (-not $settings.AiEnabled -or ((Get-Date) - $script:lastWarm).TotalMinutes -lt 10) { return }
    $script:lastWarm = Get-Date
    if ($script:warmJob) { try { $script:warmJob.Dispose() } catch {} }
    $script:warmJob = [powershell]::Create()
    [void]$script:warmJob.AddScript({
        param($model, $url)
        $b = @{ model = $model; keep_alive = '30m' } | ConvertTo-Json
        try { [void](Invoke-RestMethod "$url/api/generate" -Method Post -Body $b -ContentType 'application/json' -TimeoutSec 120) } catch {}
    }).AddArgument($aiModel).AddArgument($aiUrl)
    [void]$script:warmJob.BeginInvoke()
}

function Receive-AiCorrections {
    foreach ($j in @($script:aiJobs)) {
        if (-not $j.Handle.IsCompleted) { continue }
        $script:aiJobs.Remove($j)
        $fixed = $null
        try {
            $fixed = @($j.PS.EndInvoke($j.Handle)) | Select-Object -First 1
            if ($j.PS.Streams.Error.Count) { throw $j.PS.Streams.Error[0].Exception }
            $script:aiStatus = $null
        } catch {
            $fixed = $null
            $msg = $_.Exception.Message
            if ($msg -ne $script:aiStatus) { Write-Log ("KI: " + $msg); $script:aiStatus = $msg }
        }
        try { $j.PS.Dispose() } catch {}
        if ($fixed) { Set-AiCorrection $j.Id $j.Orig $fixed }
    }
    if ($script:aiJobs.Count -eq 0) { $aiTimer.Stop() }
}

function Set-AiCorrection($id, [string]$orig, $result) {
    $i = Find-TodoIndex $id
    if ($i -lt 0 -or $id -eq $script:editingId -or -not $result) { return }
    $item = $todos[$i]
    $isCal = $item.Source -eq 'calendar'

    # 1. Tippfehler (nur kleine Korrekturen, Termin-Titel bleiben wie im Kalender)
    $merged = if ($isCal -or -not $result.text) { $orig } else { Merge-Correction $orig ([string]$result.text) }
    $p = Get-TimeInfo $merged
    if ($isCal) { $p = @{ Text = $orig; Due = $null; Kind = $item.Kind } }
    if (-not $p.Text) { return }
    $full = $p.Text

    # 2. Lange Eintraege kurz anzeigen, Volltext bleibt im Tooltip / beim Bearbeiten
    $display = $full; $fullText = $null
    if ($full.Length -ge $shortenFrom -and (Test-ShortOk $merged ([string]$result.short))) {
        $sp = Get-TimeInfo ([string]$result.short)
        if ($sp.Text) {
            $display = $sp.Text; $fullText = $full
            if (-not $isCal -and -not $p.Due -and $sp.Due) { $p.Due = $sp.Due; $p.Kind = $sp.Kind }   # z.B. "Frist 2.11."
        }
    }
    if ($display -ceq $item.Text -and $fullText -eq $item.FullText -and ($isCal -or -not $p.Due -or $item.Due)) { return }

    $item.Text = $display
    $item.FullText = $fullText
    if (-not $isCal -and -not $item.Due -and $p.Due) { $item.Due = $p.Due; $item.Kind = $p.Kind; $item.Notified = $false; $item.Stage = 0 }
    Show-Todos
    Save-State
}

function Test-Ai {
    try {
        $tags = Invoke-RestMethod "$aiUrl/api/tags" -TimeoutSec 2
        if (@($tags.models | ForEach-Object { $_.name }) -contains $aiModel) { return "Aktiv (lokales Modell $aiModel)." }
        return "Modell $aiModel fehlt. Bitte setup.bat ausf$($ue)hren."
    } catch {
        return "Lokale KI nicht gefunden. Bitte setup.bat ausf$($ue)hren."
    }
}

# ---------- Liste ----------
function Find-TodoIndex($id) {
    for ($i = 0; $i -lt $todos.Count; $i++) { if ($todos[$i].Id -eq $id) { return $i } }
    return -1
}

function Set-BgOpacity {
    $root.Background = New-Brush ([byte][math]::Round(255 * $script:bgOpacity)) 0x18 0x18 0x18
}

function Update-Pin {
    if ($window.Topmost) { $pinBtn.Content = [string][char]0xE718; $pinBtn.Opacity = 1.0 }
    else                 { $pinBtn.Content = [string][char]0xE77A; $pinBtn.Opacity = 0.5 }
}

# Aufgaben weit in der Zukunft erst kurz vorher zeigen, damit die Liste nicht vollgemuellt ist
function Test-Visible($item) {
    # mit Stern markierte Aufgaben sind immer sichtbar
    $item.Important -or -not $item.Due -or $item.Source -eq 'calendar' -or $item.Due -le (Get-Date).AddDays($showAheadDays)
}

function Show-Todos {
    $list.Children.Clear()
    $script:editBox = $null
    $hidden = 0
    foreach ($item in $todos) {
        $later = -not (Test-Visible $item)
        if ($later) {
            $hidden++
            if (-not $script:showLater) { continue }
        }
        $row = New-Object System.Windows.Controls.Grid
        $row.Uid = $item.Id
        $row.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
        if ($later) { $row.Opacity = 0.5 }
        $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = [System.Windows.GridLength]::Auto
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
        [void]$row.ColumnDefinitions.Add($c0)
        [void]$row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
        [void]$row.ColumnDefinitions.Add($c2)

        # Kreis zum Abhaken
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = $checkStyle
        $btn.Uid = $item.Id
        $btn.ToolTip = 'Erledigt'
        $btn.VerticalAlignment = 'Top'
        $btn.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
        $btn.Add_Click({ Complete-Todo $this })
        [void]$row.Children.Add($btn)

        if ($item.Id -eq $script:editingId) {
            # Bearbeiten-Modus
            $box = New-Object System.Windows.Controls.TextBox
            $box.Style = $editStyle
            $box.Text = Format-EditText $item
            $box.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
            $box.Add_KeyDown({
                if ($_.Key -eq 'Return') { Complete-Edit $this.Text; $_.Handled = $true }
                elseif ($_.Key -eq 'Escape') { $script:editingId = $null; Show-Todos; $_.Handled = $true }
            })
            $box.Add_LostKeyboardFocus({ if ($script:editingId) { Complete-Edit $this.Text } })
            [System.Windows.Controls.Grid]::SetColumn($box, 1)
            [System.Windows.Controls.Grid]::SetColumnSpan($box, 2)
            [void]$row.Children.Add($box)
            $script:editBox = $box
        } else {
            # Text (+ Uhrzeit-Zeile); ziehen = sortieren, Doppelklick = bearbeiten
            $panel = New-Object System.Windows.Controls.StackPanel
            $panel.Tag = 'drag'
            $panel.Uid = $item.Id
            $panel.HorizontalAlignment = 'Left'
            $panel.Background = [System.Windows.Media.Brushes]::Transparent
            $panel.Margin = [System.Windows.Thickness]::new(10, 0, 4, 0)

            if ($item.FullText) { $panel.ToolTip = $item.FullText }
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Text = $item.Text
            $tb.TextWrapping = 'Wrap'
            $tb.Foreground = if ($item.Important) { $goldBrush } else { $textBrush }
            [void]$panel.Children.Add($tb)

            if ($item.Due) {
                $badge = New-Object System.Windows.Controls.TextBlock
                $badge.FontSize = 11
                $badge.Margin = [System.Windows.Thickness]::new(0, 1, 0, 0)
                $isCal = $item.Source -eq 'calendar'
                $badge.Foreground = if ($item.Notified -and -not $isCal) { $overdueBrush } else { $mutedBrush }
                $glyph = New-Object System.Windows.Documents.Run ([string][char]$(if ($isCal) { 0xE787 } else { 0xEA8F }))
                $glyph.FontFamily = $iconFont
                [void]$badge.Inlines.Add($glyph)
                $label = if ($isCal -and $item.End) { '  {0} - {1:HH:mm}' -f (Format-Due $item.Due), $item.End } else { '  {0} {1}' -f $item.Kind, (Format-Due $item.Due) }
                [void]$badge.Inlines.Add((New-Object System.Windows.Documents.Run $label))
                [void]$panel.Children.Add($badge)
            }

            $panel.Add_MouseLeftButtonDown({
                if ($_.ClickCount -ge 2) {
                    $script:dragId = $null
                    $script:editingId = $this.Uid
                    [void]$window.Dispatcher.BeginInvoke([action]{ Show-Todos })
                    $_.Handled = $true
                    return
                }
                $script:dragId = $this.Uid
                $script:dragStart = $_.GetPosition($list)
            })
            $panel.Add_MouseMove({
                if (-not $script:dragId -or $_.LeftButton -ne 'Pressed') { return }
                if ([math]::Abs($_.GetPosition($list).Y - $script:dragStart.Y) -lt 6) { return }
                $id = $script:dragId
                $script:dragId = $null
                $this.Opacity = 0.4
                [void][System.Windows.DragDrop]::DoDragDrop($this, [string]$id, [System.Windows.DragDropEffects]::Move)
                Show-Todos
            })
            [System.Windows.Controls.Grid]::SetColumn($panel, 1)
            [void]$row.Children.Add($panel)

            # Stern = wichtig
            $star = New-Object System.Windows.Controls.Button
            $star.Style = $iconStyle
            $star.Width = 22; $star.Height = 22
            $star.VerticalAlignment = 'Top'
            $star.Uid = $item.Id
            $star.ToolTip = 'Wichtig'
            $star.Content = [string][char]$(if ($item.Important) { 0xE735 } else { 0xE734 })
            $star.Foreground = if ($item.Important) { $goldBrush } else { $faintBrush }
            $star.Add_Click({ Switch-Important $this.Uid })
            [System.Windows.Controls.Grid]::SetColumn($star, 2)
            [void]$row.Children.Add($star)
        }
        [void]$list.Children.Add($row)
    }

    # "3 geplant - anzeigen"
    $script:hiddenCount = $hidden
    if ($hidden -eq 0) { $script:showLater = $false }
    else {
        $link = New-Object System.Windows.Controls.Button
        $link.Style = $linkStyle
        $link.Content = '{0} geplant {1} {2}' -f $hidden, [char]0x2013, $(if ($script:showLater) { 'ausblenden' } else { 'anzeigen' })
        $link.ToolTip = "Aufgaben mit Datum erscheinen $showAheadDays Tage vorher automatisch"
        $link.Add_Click({ $script:showLater = -not $script:showLater; Show-Todos })
        [void]$list.Children.Add($link)
    }

    if ($script:editBox) {
        [void]$window.Dispatcher.BeginInvoke([action]{
            if ($script:editBox) { [void]$script:editBox.Focus(); $script:editBox.SelectAll() }
        }, [System.Windows.Threading.DispatcherPriority]::Input)
    }
}

function Add-Todo([string]$text) {
    $p = Get-TimeInfo $text
    if (-not $p.Text) { return }
    $item = New-Todo $p.Text $false $p.Due $false 'manual' $null $p.Kind
    [void]$todos.Add($item)
    Show-Todos
    Save-State
    $scroll.ScrollToEnd()
    Start-AiCorrection $item.Id $text
}

function Complete-Edit([string]$text) {
    $id = $script:editingId
    if (-not $id) { return }
    $script:editingId = $null
    $i = Find-TodoIndex $id
    if ($i -ge 0) {
        $item = $todos[$i]
        if ($item.Source -eq 'calendar') {
            if ($text.Trim()) { $item.Text = $text.Trim(); $item.FullText = $null }
        } else {
            $p = Get-TimeInfo $text
            if ($p.Text) {
                $item.Text = $p.Text
                $item.FullText = $null
                if ($p.Due -ne $item.Due) { $item.Notified = $false; $item.Stage = 0 }
                $item.Due = $p.Due
                $item.Kind = $p.Kind
                Start-AiCorrection $item.Id $text
            }
        }
    }
    Show-Todos
    Save-State
}

function Complete-Todo($btn) {
    # kurz abhaken, dann entfernen
    $btn.IsHitTestVisible = $false
    $btn.Background = $doneBrush
    $btn.Content = [string][char]0xE73E
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(300)
    $timer.Tag = $btn.Uid
    $timer.Add_Tick({ $this.Stop(); Remove-Todo $this.Tag })
    $timer.Start()
}

function Remove-Todo($id, [bool]$undoable = $true) {
    $i = Find-TodoIndex $id
    if ($i -lt 0) { return }
    if ($undoable) {
        $script:undoStack.Push(@{ Item = $todos[$i]; Index = $i })
        $undoBtn.Visibility = 'Visible'
        $undoTimer.Stop(); $undoTimer.Start()
    }
    $todos.RemoveAt($i)
    Show-Todos
    Save-State
}

function Undo-Remove {
    if ($script:undoStack.Count -eq 0) { return }
    $u = $script:undoStack.Pop()
    $todos.Insert([math]::Min([int]$u.Index, $todos.Count), $u.Item)
    if ($script:undoStack.Count -eq 0) { $undoBtn.Visibility = 'Collapsed' }
    Show-Todos
    Save-State
}

function Switch-Important($id) {
    $i = Find-TodoIndex $id
    if ($i -lt 0) { return }
    $item = $todos[$i]
    $item.Important = -not $item.Important
    if ($item.Important -and $i -gt 0) { $todos.RemoveAt($i); $todos.Insert(0, $item) }
    Show-Todos
    Save-State
}

function Move-ToTop($item) {
    $i = Find-TodoIndex $item.Id
    if ($i -gt 0) { $todos.RemoveAt($i); $todos.Insert(0, $item) }
}

# ---------- Kalender: alle Outlook-Kalender + optional Google (iCal-Link) ----------
# Laeuft im Hintergrund, damit das Fenster nie haengt.
$calendarFetchScript = @'
param([datetime]$from, [datetime]$to, [string[]]$icsUrls, [string[]]$calendarIds)

function Out-Ev($src, $title, [datetime]$start, [datetime]$end, [bool]$allDay) {
    if (-not $title) { $title = '(ohne Titel)' }
    [pscustomobject]@{ Kind = 'event'; Key = ('ev|' + $title + '|' + $start.ToString('s')); Title = [string]$title
                       Start = $start; End = $end; AllDay = $allDay; Source = $src }
}
function Out-Err($src, $msg) { [pscustomobject]@{ Kind = 'error'; Source = $src; Message = $msg } }

# --- Outlook: immer der eigene Hauptkalender; weitere Kalender (Unterordner, Internet-Kalender) nur wenn angehakt
try {
    $ol = New-Object -ComObject Outlook.Application
    $ns = $ol.GetNamespace('MAPI')
    $defaultId = $ns.GetDefaultFolder(9).EntryID
    $folders = New-Object System.Collections.ArrayList
    $known = @{}
    function Add-Folder($f) {
        if (-not $f -or $known.ContainsKey($f.EntryID)) { return }
        $known[$f.EntryID] = 1
        [void]$folders.Add($f)
        foreach ($sub in $f.Folders) { if ($sub.DefaultItemType -eq 1) { Add-Folder $sub } }
    }
    foreach ($store in $ns.Stores) {
        try { Add-Folder $store.GetDefaultFolder(9) } catch {}
        try { foreach ($f in $store.GetRootFolder().Folders) { if ($f.DefaultItemType -eq 1) { Add-Folder $f } } } catch {}
    }
    $filter = "[End] >= '{0}' AND [Start] <= '{1}'" -f $from.ToString('g'), $to.ToString('g')
    foreach ($f in $folders) {
        $isDefault = $f.EntryID -eq $defaultId
        [pscustomobject]@{ Kind = 'folder'; Id = $f.EntryID; Name = [string]$f.Name; IsDefault = $isDefault }
        if (-not $isDefault -and -not ($calendarIds -contains $f.EntryID)) { continue }
        try {
            $items = $f.Items
            $items.Sort('[Start]')
            $items.IncludeRecurrences = $true
            $n = 0
            foreach ($a in $items.Restrict($filter)) {
                $n++
                if ($n -gt 300) { break }
                if ($a.ResponseStatus -eq 4 -or $a.MeetingStatus -eq 5 -or $a.MeetingStatus -eq 7) { continue }   # abgelehnt / abgesagt
                if ($a.Subject -match '^(Canceled|Cancelled|Abgesagt)\s*:') { continue }
                Out-Ev 'Outlook' $a.Subject ([datetime]$a.Start) ([datetime]$a.End) ([bool]$a.AllDayEvent)
            }
        } catch {}
    }
} catch {
    Out-Err 'Outlook' $_.Exception.Message
}

# --- iCal-Links (Google: "Privatadresse im iCal-Format")
$tzMap = @{ 'Europe/Vienna' = 'W. Europe Standard Time'; 'Europe/Berlin' = 'W. Europe Standard Time'; 'Europe/Zurich' = 'W. Europe Standard Time'
            'Europe/Amsterdam' = 'W. Europe Standard Time'; 'Europe/Rome' = 'W. Europe Standard Time'; 'Europe/Paris' = 'Romance Standard Time'
            'Europe/London' = 'GMT Standard Time'; 'UTC' = 'UTC'; 'Etc/UTC' = 'UTC'
            'America/New_York' = 'Eastern Standard Time'; 'America/Chicago' = 'Central Standard Time'; 'America/Los_Angeles' = 'Pacific Standard Time' }
$dayMap = @{ MO = 'Monday'; TU = 'Tuesday'; WE = 'Wednesday'; TH = 'Thursday'; FR = 'Friday'; SA = 'Saturday'; SU = 'Sunday' }

function Convert-IcsDate([string]$val, $tzid) {
    $val = $val.Trim()
    if ($val -match '^(\d{4})(\d{2})(\d{2})$') {
        return @{ Date = [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]); AllDay = $true }
    }
    if ($val -match '^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$') {
        $d = [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4], [int]$Matches[5], [int]$Matches[6])
        if ($Matches[7] -eq 'Z') { $d = [datetime]::SpecifyKind($d, 'Utc').ToLocalTime() }
        elseif ($tzid) {
            $id = $tzid.Trim('"')
            if ($tzMap.ContainsKey($id)) { $id = $tzMap[$id] }
            try { $d = [TimeZoneInfo]::ConvertTime($d, [TimeZoneInfo]::FindSystemTimeZoneById($id), [TimeZoneInfo]::Local) } catch {}
        }
        return @{ Date = [datetime]::SpecifyKind($d, 'Unspecified'); AllDay = $false }
    }
    return $null
}

function Expand-IcsEvent($ev, $skip) {
    if (-not $ev.Start -or $ev.Status -eq 'CANCELLED') { return }
    $s = $ev.Start.Date
    $dur = if ($ev.End) { $ev.End.Date - $s } elseif ($ev.Start.AllDay) { [timespan]::FromDays(1) } else { [timespan]::FromHours(1) }
    $emit = {
        param([datetime]$d)
        if (($d + $dur) -ge $from -and $d -le $to -and -not ($ev.ExDates -contains $d) -and -not ($skip -contains $d)) {
            Out-Ev 'Google' $ev.Summary $d ($d + $dur) $ev.Start.AllDay
        }
    }
    if (-not $ev.RRule) { & $emit $s; return }

    $r = @{}
    foreach ($p in $ev.RRule -split ';') { $kv = $p -split '=', 2; if ($kv.Count -eq 2) { $r[$kv[0].ToUpper()] = $kv[1] } }
    $interval = if ($r['INTERVAL']) { [int]$r['INTERVAL'] } else { 1 }
    $count = if ($r['COUNT']) { [int]$r['COUNT'] } else { [int]::MaxValue }   # nicht $r.COUNT: das waere die Anzahl der Eintraege
    $until = [datetime]::MaxValue
    if ($r['UNTIL']) { $u = Convert-IcsDate $r['UNTIL'] $null; if ($u) { $until = if ($u.AllDay) { $u.Date.AddDays(1) } else { $u.Date } } }
    $days = @(); if ($r['BYDAY']) { $days = @($r['BYDAY'] -split ',') }
    $n = 0; $guard = 0

    if ($r['FREQ'] -eq 'DAILY') {
        $d = $s
        while ($d -le $to -and $d -le $until -and $n -lt $count -and $guard -lt 20000) { & $emit $d; $n++; $guard++; $d = $d.AddDays($interval) }
    } elseif ($r['FREQ'] -eq 'WEEKLY') {
        $wd = if ($days.Count) { @($days | ForEach-Object { [int][DayOfWeek]$dayMap[$_.Substring($_.Length - 2)] }) } else { @([int]$s.DayOfWeek) }
        $offsets = @($wd | ForEach-Object { ($_ + 6) % 7 } | Sort-Object)
        $weekStart = $s.Date.AddDays(-(([int]$s.DayOfWeek + 6) % 7))
        $done = $false
        while (-not $done -and $guard -lt 5000) {
            $guard++
            foreach ($o in $offsets) {
                $d = $weekStart.AddDays($o).Add($s.TimeOfDay)
                if ($d -lt $s) { continue }
                if ($d -gt $to -or $d -gt $until -or $n -ge $count) { $done = $true; break }
                & $emit $d; $n++
            }
            $weekStart = $weekStart.AddDays(7 * $interval)
        }
    } elseif ($r['FREQ'] -eq 'MONTHLY') {
        $k = 0
        while ($guard -lt 5000) {
            $guard++
            $base = $s.AddMonths($k * $interval); $k++
            $d = $base
            if ($days.Count -and $days[0] -match '^([+-]?\d)?(MO|TU|WE|TH|FR|SA|SU)$') {
                $nth = if ($Matches[1]) { [int]$Matches[1] } else { 1 }
                $dow = [int][DayOfWeek]$dayMap[$Matches[2]]
                $first = [datetime]::new($base.Year, $base.Month, 1).Add($s.TimeOfDay)
                if ($nth -gt 0) { $d = $first.AddDays(((7 + $dow - [int]$first.DayOfWeek) % 7) + 7 * ($nth - 1)) }
                else { $last = $first.AddMonths(1).AddDays(-1); $d = $last.AddDays(-((7 + [int]$last.DayOfWeek - $dow) % 7) + 7 * ($nth + 1)) }
                if ($d.Month -ne $base.Month) { continue }
            }
            if ($d -lt $s) { continue }
            if ($d -gt $to -or $d -gt $until -or $n -ge $count) { break }
            & $emit $d; $n++
        }
    } elseif ($r['FREQ'] -eq 'YEARLY') {
        $k = 0
        while ($guard -lt 2000) {
            $guard++
            $d = $s.AddYears($k * $interval); $k++
            if ($d -gt $to -or $d -gt $until -or $n -ge $count) { break }
            & $emit $d; $n++
        }
    }
}

foreach ($url in @($icsUrls | Where-Object { $_ })) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        $raw = $wc.DownloadString(($url.Trim() -replace '^webcal://', 'https://'))
        if ($raw -notmatch 'BEGIN:VCALENDAR') { throw 'Kein Kalender unter diesem Link.' }
        $raw = $raw -replace "\r?\n[ \t]", ''   # gefaltete Zeilen zusammenfuegen
        $all = New-Object System.Collections.ArrayList
        $ev = $null
        foreach ($line in ($raw -split "\r?\n")) {
            if ($line -eq 'BEGIN:VEVENT') { $ev = @{ ExDates = @() }; continue }
            if ($line -eq 'END:VEVENT') { if ($ev) { [void]$all.Add($ev) }; $ev = $null; continue }
            if ($null -eq $ev) { continue }
            $m = [regex]::Match($line, '^((?:[^:"]|"[^"]*")*):(.*)$')   # Doppelpunkt ausserhalb von Anfuehrungszeichen
            if (-not $m.Success) { continue }
            $name = $m.Groups[1].Value; $val = $m.Groups[2].Value
            $tzid = $null; if ($name -match 'TZID=([^;]+)') { $tzid = $Matches[1] }
            $prop = ($name -split ';')[0].ToUpper()
            if ($prop -eq 'SUMMARY') { $ev.Summary = ($val -replace '\\n', ' ') -replace '\\([,;\\])', '$1' }
            elseif ($prop -eq 'DTSTART') { $ev.Start = Convert-IcsDate $val $tzid }
            elseif ($prop -eq 'DTEND') { $ev.End = Convert-IcsDate $val $tzid }
            elseif ($prop -eq 'RRULE') { $ev.RRule = $val }
            elseif ($prop -eq 'EXDATE') { foreach ($x in $val -split ',') { $p = Convert-IcsDate $x $tzid; if ($p) { $ev.ExDates += $p.Date } } }
            elseif ($prop -eq 'RECURRENCE-ID') { $p = Convert-IcsDate $val $tzid; if ($p) { $ev.RecurrenceId = $p.Date } }
            elseif ($prop -eq 'STATUS') { $ev.Status = $val.Trim() }
            elseif ($prop -eq 'UID') { $ev.Uid = $val.Trim() }
        }
        # verschobene Einzeltermine einer Serie ersetzen den Original-Termin
        $overrides = @{}
        foreach ($e in $all) {
            if ($e.RecurrenceId -and $e.Uid) {
                if (-not $overrides[$e.Uid]) { $overrides[$e.Uid] = New-Object System.Collections.ArrayList }
                [void]$overrides[$e.Uid].Add($e.RecurrenceId)
            }
        }
        foreach ($e in $all) {
            $skip = @(); if (-not $e.RecurrenceId -and $e.Uid -and $overrides[$e.Uid]) { $skip = @($overrides[$e.Uid]) }
            if ($e.RecurrenceId) { $e.RRule = $null }
            Expand-IcsEvent $e $skip
        }
    } catch {
        Out-Err 'Google' $_.Exception.Message
    }
}
'@

$script:calJob = $null
$script:lastCalError = $null
$script:calSources = @()
$script:calFolders = @()

function Start-CalendarFetch {
    if ($script:calJob -or -not $settings.CalendarEnabled) { return }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $now = Get-Date
    [void]$ps.AddScript($calendarFetchScript).AddArgument($now.AddHours(-12)).AddArgument($now.Date.AddDays(15)).AddArgument([string[]]@($settings.IcsUrls)).AddArgument([string[]]@($settings.CalendarIds))
    $script:calJob = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}

function Receive-CalendarFetch {
    $job = $script:calJob
    if (-not $job -or -not $job.Handle.IsCompleted) { return }
    $script:calJob = $null
    $events = @{}
    $errors = @{}
    $folders = New-Object System.Collections.ArrayList
    try {
        foreach ($r in $job.PS.EndInvoke($job.Handle)) {
            if ($r.Kind -eq 'folder') { if (-not $r.IsDefault) { [void]$folders.Add($r) } }
            elseif ($r.Kind -eq 'event') { if (-not $events.ContainsKey($r.Key)) { $events[$r.Key] = $r } }   # doppelte (Outlook + Google) zusammenfuehren
            elseif ($r.Kind -eq 'error') { $errors[$r.Source] = $r.Message }
        }
    } catch { $errors['Outlook'] = $_.Exception.Message }
    try { $job.PS.Dispose(); $job.RS.Close() } catch {}
    if (-not $settings.CalendarEnabled) { return }

    if (-not $errors['Outlook']) { $script:calFolders = @($folders) }
    $script:events = @($events.Values | Sort-Object Start)
    $script:calSources = @($script:events | ForEach-Object { $_.Source } | Sort-Object -Unique)

    $parts = @()
    if (-not $errors['Outlook']) { $parts += 'Outlook' }
    if (@($settings.IcsUrls).Count -and -not $errors['Google']) { $parts += 'Google' }
    $status = if ($parts.Count) { 'Verbunden: ' + ($parts -join ' + ') + '.' } else { 'Kein Kalender verbunden.' }
    if ($errors['Outlook'] -and -not @($settings.IcsUrls).Count) { $status = 'Outlook (classic) nicht gefunden. Du kannst unten einen Google-Kalender eintragen.' }
    if ($errors['Google']) { $status += ' Der Google-Link funktioniert nicht, bitte pr' + $ue + 'fen.' }
    $script:calStatus = $status

    $msg = ($errors.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join ' | '
    if ($msg -and $msg -ne $script:lastCalError) { Write-Log ("Kalender: " + $msg) }
    $script:lastCalError = $msg

    Update-SettingsStatus
    Invoke-ReminderCheck
}

# import.txt im Ordner: jede Zeile wird eine Aufgabe (Zeiten werden erkannt), danach wird die Datei geloescht
$importFile = Join-Path $PSScriptRoot 'import.txt'
function Import-Inbox {
    if (-not (Test-Path $importFile)) { return }
    try {
        $lines = @(Get-Content $importFile -Encoding UTF8 -TotalCount 200)   # Obergrenze gegen Riesendateien
        Remove-Item $importFile
    } catch { return }   # Datei wird evtl. gerade noch geschrieben
    $added = 0
    foreach ($l in $lines) {
        if (-not $l.Trim()) { continue }
        $p = Get-TimeInfo $l.Trim()
        if (-not $p.Text) { continue }
        $new = New-Todo $p.Text $false $p.Due $false 'manual' $null $p.Kind
        [void]$todos.Add($new)
        Start-AiCorrection $new.Id $l.Trim()
        $added++
    }
    if ($added) {
        Write-Log "Import: $added Aufgabe(n) aus import.txt"
        Show-Todos
        Save-State
    }
}

function Show-Notification($title, $text) {
    if (-not $text) { $text = ' ' }
    $tray.BalloonTipTitle = $title
    $tray.BalloonTipText = $text
    $tray.ShowBalloonTip(10000)
}

function Invoke-ReminderCheck {
    $now = Get-Date
    $changed = $false

    # Termine 15 Minuten vorher oben einreihen
    if ($settings.CalendarEnabled) {
        foreach ($ev in @($script:events)) {
            if ($ev.AllDay -or $script:seen.ContainsKey($ev.Key)) { continue }
            if ($now -ge $ev.Start.AddMinutes(-$leadMinutes) -and $now -lt $ev.End) {
                $script:seen[$ev.Key] = $ev.Start.ToString('s')
                $calItem = New-Todo $ev.Title $true $ev.Start $true 'calendar' $ev.End
                $todos.Insert(0, $calItem)
                if ($ev.Title.Length -ge $shortenFrom) { Start-AiCorrection $calItem.Id $ev.Title }
                Show-Notification ("Termin um {0:HH:mm}" -f $ev.Start) $ev.Title
                $changed = $true
            }
        }
    }

    # Vorbei? Dann Termin wieder entfernen
    foreach ($t in @($todos)) {
        if ($t.Source -eq 'calendar') {
            $end = if ($t.End) { $t.End } elseif ($t.Due) { $t.Due.AddHours(1) } else { $null }
            if ($end -and $now -ge $end -and $t.Id -ne $script:editingId) {
                $todos.RemoveAt((Find-TodoIndex $t.Id))
                $changed = $true
            }
        }
    }

    # Eigene Erinnerungen: "um" 5 Min. vorher, "bis" 30 Min. vorher, Anmeldungen 30 + 5 Min. vorher
    foreach ($t in @($todos)) {
        if ($t.Source -eq 'calendar' -or -not $t.Due -or $t.Notified) { continue }
        $leads = @(Get-Leads $t)
        $stage = [int]$t.Stage
        $fire = $false
        while ($stage -lt $leads.Count -and $now -ge $t.Due.AddMinutes(-$leads[$stage])) { $stage++; $fire = $true }
        if ($fire) {
            $t.Stage = $stage
            $t.Notified = $stage -ge $leads.Count
            Move-ToTop $t
            $mins = [math]::Ceiling(($t.Due - $now).TotalMinutes)
            $when = if ($mins -gt 0) { " (in $mins Min.)" } else { '' }
            $title = if ($t.Kind -eq 'bis') { 'Erledigen bis {0:HH:mm}{1}' -f $t.Due, $when } else { 'Um {0:HH:mm}{1}' -f $t.Due, $when }
            Show-Notification $title $t.Text
            $changed = $true
        }
    }

    if ($changed) {
        if (-not (Test-Shown)) { Restore-Planer $false }
        if (-not $script:editingId) { Show-Todos }
        Save-State
    } elseif (-not $script:editingId -and -not $script:dragId) {
        # geplante Aufgabe ist jetzt nah genug -> wieder anzeigen
        $hidden = @($todos | Where-Object { -not (Test-Visible $_) }).Count
        if ($hidden -ne $script:hiddenCount) { Show-Todos }
    }
}

# ---------- Einstellungen: Kalender, Google-Link, KI ----------
$script:S = $null

function Update-SettingsStatus {
    if (-not $script:S) { return }
    $script:S.Status.Text = if ($settings.CalendarEnabled) { $script:calStatus } else { 'Aus.' }
    if ($script:S.Status.Text -eq '') { $script:S.Status.Text = 'Verbinde ...' }
    if ($script:hotkeyProblem) { $script:S.Status.Text += "`nHinweis: Strg+Alt+T ist schon von einem anderen Programm belegt." }
    Update-CalFolders
    Update-Agenda
}

# Weitere Outlook-Kalender (z.B. Kollegen, Feiertage, Kurse) einzeln zum Anhaken
function Update-CalFolders {
    if (-not $script:S) { return }
    $panel = $script:S.Folders
    $panel.Children.Clear()
    if (-not $settings.CalendarEnabled -or @($script:calFolders).Count -eq 0) { return }
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = 'Weitere Kalender anzeigen:'
    $h.FontSize = 12; $h.Opacity = 0.65; $h.Margin = [System.Windows.Thickness]::new(0, 4, 0, 2)
    [void]$panel.Children.Add($h)
    foreach ($f in $script:calFolders) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $f.Name
        $cb.Tag = $f.Id
        $cb.Foreground = [System.Windows.Media.Brushes]::White
        $cb.FontSize = 12
        $cb.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        $cb.IsChecked = @($settings.CalendarIds) -contains $f.Id
        $cb.Add_Click({
            $ids = @(@($settings.CalendarIds) | Where-Object { $_ -and $_ -ne $this.Tag })
            if ($this.IsChecked) { $ids += $this.Tag }
            $settings.CalendarIds = $ids
            Save-Settings
            $script:calStatus = 'Lade Kalender ...'
            $script:S.Status.Text = $script:calStatus
            $script:nextFetch = Get-Date   # falls gerade ein Abruf laeuft: direkt danach nochmal
            Start-CalendarFetch
        })
        [void]$panel.Children.Add($cb)
    }
}

# Uebersicht der naechsten 14 Tage: Outlook (blau), Google (gruen), eigene Aufgaben mit Zeit (gelb)
function Update-Agenda {
    if (-not $script:S) { return }
    $panel = $script:S.Agenda
    $panel.Children.Clear()
    $now = Get-Date
    $until = $now.Date.AddDays(15)
    $entries = New-Object System.Collections.ArrayList
    if ($settings.CalendarEnabled) {
        foreach ($ev in @($script:events)) {
            if ($ev.End -gt $now -and $ev.Start -lt $until) {
                $c = if ($ev.Source -eq 'Google') { $googleBrush } else { $outlookBrush }
                [void]$entries.Add(@{ Start = $ev.Start; Title = $ev.Title; AllDay = [bool]$ev.AllDay; Brush = $c })
            }
        }
    }
    foreach ($t in $todos) {
        if ($t.Due -and $t.Source -ne 'calendar' -and $t.Due -gt $now.AddHours(-1) -and $t.Due -lt $until) {
            $title = if ($t.FullText) { $t.FullText } else { $t.Text }
            if ($t.Kind -eq 'bis') { $title = 'bis: ' + $title }
            [void]$entries.Add(@{ Start = $t.Due; Title = $title; AllDay = $false; Brush = $goldBrush })
        }
    }
    if ($entries.Count -eq 0) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = if ($settings.CalendarEnabled) { "Keine Termine in den n$($ae)chsten 14 Tagen." } else { 'Kalender ist aus.' }
        $tb.Opacity = 0.6; $tb.FontSize = 12; $tb.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
        [void]$panel.Children.Add($tb)
        return
    }
    $lastDay = $null
    foreach ($e in $entries) { $e.Day = if ($e.Start -lt $now.Date) { $now.Date } else { $e.Start.Date } }   # laufende Termine unter "Heute"
    foreach ($e in ($entries | Sort-Object { $_.Day }, { -not $_.AllDay }, { $_.Start })) {
        if ($e.Day -ne $lastDay) {
            $lastDay = $e.Day
            $h = New-Object System.Windows.Controls.TextBlock
            $h.Text = if ($lastDay -eq $now.Date) { 'Heute' } elseif ($lastDay -eq $now.Date.AddDays(1)) { 'Morgen' } else { $lastDay.ToString('dddd, dd.MM.') }
            $h.FontWeight = 'SemiBold'; $h.FontSize = 12
            $h.Margin = [System.Windows.Thickness]::new(0, 6, 0, 2)
            [void]$panel.Children.Add($h)
        }
        $row = New-Object System.Windows.Controls.DockPanel
        $row.Margin = [System.Windows.Thickness]::new(0, 1, 0, 1)
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 7; $dot.Height = 7; $dot.Fill = $e.Brush
        $dot.VerticalAlignment = 'Top'; $dot.Margin = [System.Windows.Thickness]::new(0, 5, 8, 0)
        [System.Windows.Controls.DockPanel]::SetDock($dot, 'Left')
        [void]$row.Children.Add($dot)
        $time = New-Object System.Windows.Controls.TextBlock
        $time.Text = if ($e.AllDay) { 'ganzt.' } else { $e.Start.ToString('HH:mm') }
        $time.Width = 42; $time.FontSize = 12; $time.Opacity = 0.7
        [System.Windows.Controls.DockPanel]::SetDock($time, 'Left')
        [void]$row.Children.Add($time)
        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = $e.Title; $title.FontSize = 12; $title.TextTrimming = 'CharacterEllipsis'; $title.ToolTip = $e.Title
        [void]$row.Children.Add($title)
        [void]$panel.Children.Add($row)
    }
}

function Show-Settings {
    if ($script:S) { [void]$script:S.Win.Activate(); return }
    if (-not (Test-Shown)) { Restore-Planer }
    $sw = [Windows.Markup.XamlReader]::Parse($settingsXaml)
    $script:S = @{
        Win         = $sw
        Switch      = $sw.FindName('CalSwitch')
        Status      = $sw.FindName('CalStatus')
        Agenda      = $sw.FindName('Agenda')
        Folders     = $sw.FindName('CalFolders')
        Ics         = $sw.FindName('IcsBox')
        IcsHint     = $sw.FindName('IcsPlaceholder')
        IcsChanged  = $false
        AiSwitch    = $sw.FindName('AiSwitch')
        AiStatus    = $sw.FindName('AiStatus')
    }
    $sw.Owner = $window
    $sw.Icon = $window.Icon
    $script:S.Switch.IsChecked = [bool]$settings.CalendarEnabled
    $script:S.AiSwitch.IsChecked = [bool]$settings.AiEnabled
    $script:S.AiStatus.Text = if ($settings.AiEnabled) { Test-Ai } else { 'Aus.' }
    $script:S.Ics.Text = (@($settings.IcsUrls) | Select-Object -First 1)
    $script:S.IcsHint.Visibility = if ($script:S.Ics.Text) { 'Collapsed' } else { 'Visible' }
    Update-SettingsStatus

    $script:S.AiSwitch.Add_Click({
        $settings.AiEnabled = [bool]$script:S.AiSwitch.IsChecked
        Save-Settings
        $script:S.AiStatus.Text = if ($settings.AiEnabled) { Test-Ai } else { 'Aus.' }
    })

    $script:S.Switch.Add_Click({
        $settings.CalendarEnabled = [bool]$script:S.Switch.IsChecked
        Save-Settings
        if ($settings.CalendarEnabled) { $script:calStatus = ''; Start-CalendarFetch } else { $script:events = @() }
        Update-SettingsStatus
    })

    # Google-Link: wird sofort gespeichert, beim Schliessen (oder Enter) neu abgerufen
    $script:S.Ics.Add_TextChanged({
        $u = $script:S.Ics.Text.Trim()
        $script:S.IcsHint.Visibility = if ($u) { 'Collapsed' } else { 'Visible' }
        $settings.IcsUrls = if ($u -match '^(https?|webcal)://') { @($u) } else { @() }
        $script:S.IcsChanged = $true
        Save-Settings
    })
    $script:S.Ics.Add_KeyDown({
        if ($_.Key -eq 'Return' -and $script:S.IcsChanged) {
            $script:S.IcsChanged = $false; $script:calStatus = 'Lade Kalender ...'; Update-SettingsStatus; Start-CalendarFetch
        }
    })

    $sw.FindName('SHeader').Add_MouseLeftButtonDown({ try { $script:S.Win.DragMove() } catch {} })
    $sw.FindName('SClose').Add_Click({ $script:S.Win.Close() })
    $sw.Add_Deactivated({ if ($script:S) { $script:S.Win.Close() } })   # wegklicken = schliessen
    $sw.Add_Closing({
        if ($script:S.IcsChanged) { $script:nextFetch = Get-Date }      # neuen Link gleich abrufen
        $script:S = $null
    })
    $sw.Show()
    [void]$sw.Activate()
}

# ---------- Fenster-Position/Groesse ----------
$window.Width   = [double]$state.Width
$window.Height  = [double]$state.Height
$window.Topmost = [bool]$state.Topmost

$sp = [System.Windows.SystemParameters]
$placed = $false
if ($null -ne $state.Left -and $null -ne $state.Top) {
    $l = [double]$state.Left; $t = [double]$state.Top
    if ($l -ge $sp::VirtualScreenLeft - 50 -and $l -le $sp::VirtualScreenLeft + $sp::VirtualScreenWidth - 80 -and
        $t -ge $sp::VirtualScreenTop - 10 -and $t -le $sp::VirtualScreenTop + $sp::VirtualScreenHeight - 50) {
        $window.Left = $l; $window.Top = $t; $placed = $true
    }
}
if (-not $placed) {
    $wa = $sp::WorkArea
    $window.Left = $wa.Right - $window.Width - 20
    $window.Top  = $wa.Top + 20
}

# ---------- Events ----------
$header.Add_MouseLeftButtonDown({
    try { $window.DragMove() } catch {}
    Save-State
})

# Alles ohne Funktion (Hintergrund, Luecken) laesst Klicks zum Fenster dahinter durch.
# Bedienbar bleiben: Titelzeile, Buttons, Aufgabentext, Eingabefeld, Groessen-Griff.
function Test-Interactive($pt) {
    # InputHitTest beachtet IsHitTestVisible (der Platzhalter-Text ueber dem Eingabefeld wird uebersprungen)
    $el = $window.InputHitTest($pt)
    while ($el) {
        if ($el -is [System.Windows.Controls.Primitives.ButtonBase] -or
            $el -is [System.Windows.Controls.Primitives.TextBoxBase] -or
            $el -is [System.Windows.Controls.Primitives.ResizeGrip] -or
            $el.Tag -eq 'drag' -or
            $el -eq $header) { return $true }
        if ($el -is [System.Windows.Media.Visual]) { $el = [System.Windows.Media.VisualTreeHelper]::GetParent($el) }
        else { $el = [System.Windows.LogicalTreeHelper]::GetParent($el) }   # z.B. Run im Text
    }
    return $false
}

$script:hwnd = [IntPtr]::Zero
$hoverTimer = New-Object System.Windows.Threading.DispatcherTimer
$hoverTimer.Interval = [TimeSpan]::FromMilliseconds(40)
$hoverTimer.Add_Tick({
    try {
        if ([TodoPlaner.Native]::LeftDown()) { return }   # waehrend Ziehen/Resize nicht umschalten
        $c  = [TodoPlaner.Native]::CursorPos()
        $pt = $window.PointFromScreen((New-Object System.Windows.Point($c[0], $c[1])))
        $through = -not (Test-Interactive $pt)
        # echten Zustand lesen: WPF setzt die Fenster-Flags z.B. beim Ein-/Ausblenden selbst zurueck
        if ($through -ne [TodoPlaner.Native]::IsClickThrough($script:hwnd)) {
            [TodoPlaner.Native]::SetClickThrough($script:hwnd, $through)
        }
    } catch {}
})

$aiTimer = New-Object System.Windows.Threading.DispatcherTimer
$aiTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$aiTimer.Add_Tick({ try { Receive-AiCorrections } catch { Write-Log ("KI: " + $_.Exception.Message) } })

$undoTimer = New-Object System.Windows.Threading.DispatcherTimer
$undoTimer.Interval = [TimeSpan]::FromSeconds(10)
$undoTimer.Add_Tick({ $this.Stop(); $undoBtn.Visibility = 'Collapsed' })

$script:nextFetch = Get-Date
$calTimer = New-Object System.Windows.Threading.DispatcherTimer
$calTimer.Interval = [TimeSpan]::FromSeconds(5)
$calTimer.Add_Tick({
    try {
        Receive-CalendarFetch
        Import-Inbox
        if ((Get-Date) -ge $script:nextFetch) {
            $script:nextFetch = (Get-Date).AddMinutes(2)
            Start-CalendarFetch
        }
        Invoke-ReminderCheck
    } catch { Write-Log ("Timer: " + $_.Exception.Message) }
})

$header.Add_MouseWheel({
    $script:bgOpacity = [math]::Min(1.0, [math]::Max(0.1, $script:bgOpacity + $_.Delta / 2400))
    Set-BgOpacity
    Save-State
})

$undoBtn.Add_Click({ Undo-Remove })
$gearBtn.Add_Click({ Show-Settings })
$pinBtn.Add_Click({ $window.Topmost = -not $window.Topmost; Update-Pin; Save-State })
$closeBtn.Add_Click({ Minimize-Planer })

# Offen: nicht in Taskleiste/Alt+Tab (schwebt eh im Vordergrund). Minimiert: in Taskleiste/Alt+Tab.
$window.Add_StateChanged({
    if ($window.WindowState -ne 'Minimized' -and $window.ShowInTaskbar) { $window.ShowInTaskbar = $false }
})

$scroll.Add_Drop({
    $id = $_.Data.GetData([System.Windows.DataFormats]::StringFormat)
    $from = Find-TodoIndex $id
    if ($from -lt 0) { return }
    # Ziel = die Zeile unter dem Mauszeiger (ausgeblendete Aufgaben haben keine Zeile)
    $y = $_.GetPosition($list).Y
    $targetId = $null
    foreach ($r in $list.Children) {
        if (-not $r.Uid) { continue }   # "geplant"-Zeile
        $top = $r.TranslatePoint((New-Object System.Windows.Point(0, 0)), $list).Y
        if ($y -lt $top + $r.ActualHeight / 2) { $targetId = $r.Uid; break }
    }
    if ($targetId -eq $id) { Show-Todos; return }
    $item = $todos[$from]
    $todos.RemoveAt($from)
    $to = if ($targetId) { Find-TodoIndex $targetId } else { $todos.Count }
    if ($to -lt 0) { $to = $todos.Count }
    $todos.Insert($to, $item)
    Show-Todos
    Save-State
})

$inputBox.Add_TextChanged({
    $placeholder.Visibility = if ($inputBox.Text) { 'Collapsed' } else { 'Visible' }
    if ($inputBox.Text) { Start-AiWarmup }
})

$inputBox.Add_KeyDown({
    if ($_.Key -eq 'Return') {
        $text = $inputBox.Text.Trim()
        if ($text) { $inputBox.Text = ''; Add-Todo $text }
        $_.Handled = $true
    } elseif ($_.Key -eq 'Escape') {
        $inputBox.Text = ''
    }
})

$window.Add_PreviewKeyDown({
    if ($_.Key -eq 'Z' -and [System.Windows.Input.Keyboard]::Modifiers -eq 'Control' -and -not $script:editingId -and
        -not ($inputBox.IsKeyboardFocused -and $inputBox.Text)) {
        Undo-Remove
        $_.Handled = $true
    }
})

$window.Add_SizeChanged({ Save-State })

# Schliessen (z.B. Alt+F4) blendet nur aus; richtig beendet wird ueber das Tray-Menue
$script:quitting = $false
$window.Add_Closing({
    if (-not $script:quitting) { $_.Cancel = $true; Minimize-Planer; return }
    Save-State
    Write-Log 'Beendet'
})

# Fehler in Event-Handlern protokollieren statt die App zu beenden
$window.Dispatcher.Add_UnhandledException({
    Write-Log ("Fehler: " + $_.Exception.ToString())
    $_.Handled = $true
})

# ---------- Globaler Hotkey Strg+Alt+T ----------
function Test-Shown { $window.IsVisible -and $window.WindowState -ne 'Minimized' }

function Minimize-Planer {
    $window.ShowInTaskbar = $true   # erst in die Taskleiste, sonst minimiert WPF in eine Mini-Titelleiste
    $window.WindowState = 'Minimized'
}

function Restore-Planer([bool]$activate = $true) {
    if (-not $window.IsVisible) { $window.Show() }
    if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
    if ($activate) { [void]$window.Activate() }
}

function Invoke-Hotkey {
    if ((Test-Shown) -and $window.IsActive) { Minimize-Planer; return }
    Restore-Planer
    [void]$inputBox.Focus()
}

$script:hotkey = $null
$script:hotkeyProblem = $false
function Register-Hotkey {
    try {
        $script:hotkey = [TodoPlaner.HotKey]::new(3, 0x54)   # MOD_ALT|MOD_CONTROL, 'T'
        if ($script:hotkey.Registered) {
            $script:hotkey.Add_Pressed({ try { Invoke-Hotkey } catch { Write-Log ("Hotkey: " + $_.Exception.Message) } })
        } else {
            $script:hotkeyProblem = $true
            Write-Log 'Hotkey Strg+Alt+T ist bereits belegt'
        }
    } catch { Write-Log ("Hotkey: " + $_.Exception.Message) }
}

$window.Add_ContentRendered({
    $script:ready = $true
    $script:hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
    $hoverTimer.Start()
    $calTimer.Start()
    Register-Hotkey
    # vorhandene lange Eintraege einmalig kuerzen lassen
    foreach ($t in @($todos)) {
        if (-not $t.FullText -and $t.Text.Length -ge $shortenFrom) { Start-AiCorrection $t.Id (Format-EditText $t) }
    }
})

# ---------- Icon + Tray ----------
$iconStream = New-Object System.IO.MemoryStream
$iconBmp = New-TodoBitmap 64
$iconBmp.Save($iconStream, [System.Drawing.Imaging.ImageFormat]::Png)
$iconStream.Position = 0
$window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($iconStream, 'None', 'OnLoad')

function Switch-Planer {
    if (Test-Shown) { Minimize-Planer }
    else { Restore-Planer }
}

$traySize = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.Icon]::FromHandle((New-TodoBitmap $traySize).GetHicon())
$tray.Text = 'Todo Planer (Strg+Alt+T)'
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$trayMenu.Items.Add('Anzeigen / Ausblenden', $null, { Switch-Planer })
[void]$trayMenu.Items.Add('Einstellungen', $null, { Show-Settings })
[void]$trayMenu.Items.Add('Beenden', $null, { $script:quitting = $true; $window.Close() })
$tray.ContextMenuStrip = $trayMenu
$tray.Add_MouseClick({ if ($_.Button -eq 'Left') { Switch-Planer } })
$tray.Add_BalloonTipClicked({ Restore-Planer })
$tray.Visible = $true

# ---------- Start ----------
Set-BgOpacity
Update-Pin
Show-Todos

$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
$app.Add_SessionEnding({ Save-State })
$window.Add_Closed({
    $tray.Visible = $false
    $tray.Dispose()
    if ($script:hotkey) { $script:hotkey.Dispose() }
    $app.Shutdown()
})

try { [void]$app.Run($window) }
catch { Write-Log ("Absturz: " + $_.Exception.ToString()) }
$tray.Dispose()
$mutex.ReleaseMutex()
