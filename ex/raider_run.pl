#!/usr/bin/env perl
# ABSTRACT: Raider demo — all self-tools, engine switching, MCP catalog
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";

binmode STDOUT, ':utf8';
$|=1;

use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Future::AsyncAwait;
use Net::Async::MCP;
use MCP::Server;
use MCP::Server::Run::Bash;
use Langertha::Engine::Anthropic;
use Langertha::Raider;
use Time::HiRes qw(time sleep);

# ── Helpers for verbose output ───────────────────────────────────────

sub banner  { printf "\n%s\n  %s\n%s\n\n", '=' x 70, $_[0], '=' x 70 }
sub info    { printf "  %s\n", $_[0] }
sub sep     { printf "  %s\n", '-' x 60 }
sub colored { sprintf "\e[%sm%s\e[0m", $_[0], $_[1] }
sub label   { sprintf "  %-22s %s\n", colored('90', $_[0] . ':'), $_[1] }

sub show_state {
  my ($raider) = @_;
  # Engine catalog
  my $engines = $raider->list_engines;
  my @engine_parts;
  for my $name (sort keys %$engines) {
    my $e = $engines->{$name};
    my $model = $e->{engine}->chat_model;
    if ($e->{active}) {
      push @engine_parts, colored('32', "$name ($model) *ACTIVE*");
    } else {
      push @engine_parts, colored('90', "$name ($model)");
    }
  }
  printf label("Engines", join('  ', @engine_parts));

  # MCP catalog
  my @mcp_parts;
  for my $name (sort keys %{$raider->mcp_catalog}) {
    my $active = exists $raider->_active_catalog_mcps->{$name};
    if ($active) {
      push @mcp_parts, colored('32', "$name *ACTIVE*");
    } else {
      push @mcp_parts, colored('90', "$name (inactive)");
    }
  }
  printf label("MCP catalog", @mcp_parts ? join('  ', @mcp_parts) : colored('33', '(all inactive)'));
}

# ── 1. MCP Server: shell (Run::Bash) ────────────────────────────────

my $project_dir = $FindBin::Bin . '/..';
my $report_file = '/tmp/raider_build_report.txt';

my $shell_server = MCP::Server::Run::Bash->new(
  name              => 'shell',
  version           => '0.001',
  allowed_commands  => [qw( ls cat head tail wc find grep file pwd du date uname prove )],
  working_directory => $project_dir,
  timeout           => 30,
);

banner("SETUP: MCP Servers");
info("Shell MCP (MCP::Server::Run::Bash)");
printf label("  commands", join(', ', @{$shell_server->allowed_commands}));
printf label("  cwd", $project_dir);
printf label("  timeout", "${\$shell_server->timeout}s");

# Wrap shell tool to log calls
{
  my $tool = $shell_server->tools->[0];
  my $orig = $tool->code;
  $tool->code(sub {
    my ($self, $args) = @_;
    my $cmd = $args->{command} // '?';
    my $wd  = $args->{working_directory} // '';
    sep();
    printf "  %s %s%s\n", colored('36', '>>> run'), $cmd, ($wd ? "  (in $wd)" : '');
    my $t0 = time;
    my $result = $orig->($self, $args);
    my $elapsed = time - $t0;
    my $text = $result->{content}[0]{text} // '';
    for my $line (split /\n/, $text) {
      printf "  %s %s\n", colored('90', '   |'), $line;
    }
    printf "  %s %s\n", colored('33', '<<< run'), sprintf('%.1fs', $elapsed);
    sep();
    return $result;
  });
}

# ── 2. MCP Server: notes (simple note-taking, starts in catalog) ────

my @notebook;

my $notes_server = MCP::Server->new(name => 'notes', version => '1.0');
$notes_server->tool(
  name         => 'save_note',
  description  => 'Save a note to the notebook. Use this to record findings.',
  input_schema => {
    type       => 'object',
    properties => {
      title => { type => 'string', description => 'Short title for the note' },
      text  => { type => 'string', description => 'Note content' },
    },
    required => ['title', 'text'],
  },
  code => sub {
    my ($self, $args) = @_;
    push @notebook, { title => $args->{title}, text => $args->{text} };
    sep();
    printf "  %s %s: %s\n", colored('34', '>>> save_note'), $args->{title}, $args->{text};
    sep();
    return $self->text_result("Note saved: $args->{title}");
  },
);
$notes_server->tool(
  name         => 'read_notes',
  description  => 'Read all saved notes from the notebook.',
  input_schema => { type => 'object', properties => {} },
  code => sub {
    my ($self, $args) = @_;
    return $self->text_result("Notebook is empty.") unless @notebook;
    my $text = join("\n\n", map { "## $_->{title}\n$_->{text}" } @notebook);
    sep();
    printf "  %s %d notes\n", colored('34', '>>> read_notes'), scalar @notebook;
    sep();
    return $self->text_result($text);
  },
);

info("");
info("Notes MCP (MCP::Server)");
printf label("  tools", "save_note, read_notes");
printf label("  status", "inactive (in mcp_catalog, LLM must activate)");
info("");
info(colored('33', "Both MCP servers start in the catalog — the LLM has NO tools"));
info(colored('33', "initially except self-tools. It must bootstrap itself!"));

# ── 3. Event loop + MCP clients ─────────────────────────────────────

my $loop = IO::Async::Loop->new;

my $shell_mcp = Net::Async::MCP->new(server => $shell_server);
$loop->add($shell_mcp);

my $notes_mcp = Net::Async::MCP->new(server => $notes_server);
$loop->add($notes_mcp);

async sub main {
  await $shell_mcp->initialize;
  await $notes_mcp->initialize;

  # ── 4. Engines ──

  banner("SETUP: Engine Catalog");

  my $api_key = $ENV{ANTHROPIC_API_KEY} || die("Set ANTHROPIC_API_KEY\n");

  my $sonnet = Langertha::Engine::Anthropic->new(
    api_key => $api_key,
    model   => 'claude-sonnet-4-6',
  );

  my $haiku = Langertha::Engine::Anthropic->new(
    api_key => $api_key,
    model   => 'claude-haiku-4-5-20251001',
  );

  info("default (Sonnet) " . colored('90', $sonnet->chat_model) . " - main engine, active at start");
  info("fast    (Haiku)  " . colored('90', $haiku->chat_model) . "  - in engine_catalog");
  info("smart   (Sonnet) " . colored('90', $sonnet->chat_model) . " - in engine_catalog");
  info("");
  info("Engines have NO mcp_servers — all tools come from the MCP catalog.");
  info("The LLM can switch engines via raider_switch_engine.");

  # ── 5. Background "build" — creates report file after 4 seconds ──

  banner("SETUP: Background Build");

  unlink $report_file;

  $loop->add(IO::Async::Timer::Countdown->new(
    delay     => 4,
    on_expire => sub {
      open my $fh, '>', $report_file or return;
      print $fh "Build OK: 42 modules compiled, 0 errors\nTimestamp: " . localtime() . "\n";
      close $fh;
      printf "\n  %s\n", colored('32', "[BACKGROUND] Build report written to $report_file");
    },
  )->start);

  info("Timer started: $report_file will appear in 4 seconds.");
  info("The LLM will use raider_wait + raider_wait_for to check for it.");

  # ── 6. Self-tools overview ──

  banner("SETUP: Raider Self-Tools");
  info("raider_switch_engine  - switch between engine catalog entries");
  info("raider_manage_mcps    - list/activate/deactivate MCP catalog entries");
  info("raider_wait           - wait N seconds");
  info("raider_wait_for       - wait for external condition (file_exists)");
  info("raider_ask_user       - ask user a question (simulated in demo)");
  info("raider_session_history- query the full session history");
  info("raider_pause          - pause execution (available but not used)");
  info("raider_abort          - abort the raid (available but not used)");

  # ── 7. Simulated user answers ──

  my @simulated_answers = (
    "Yes, run the tests with prove -l t/ and tell me how it went.",
    "Wrap it up.",
  );
  my $answer_idx = 0;

  # ── 8. State tracking for change detection ──

  my $prev_engine = 'default';
  my %prev_active_mcps;

  # ── 9. Raider ──

  my $raider = Langertha::Raider->new(
    engine  => $sonnet,
    max_iterations => 25,
    engine_catalog => {
      fast  => { engine => $haiku,  description => 'Fast model for quick tasks' },
      smart => { engine => $sonnet, description => 'Smart model for analysis' },
    },
    mcp_catalog => {
      shell => { server => $shell_mcp, description => 'Shell command execution (run tool)' },
      notes => { server => $notes_mcp, description => 'Notebook for saving findings' },
    },
    raider_mcp => 1,
    mission => join("\n",
      'You are a build engineer. You start with NO tools except self-tools.',
      'You must activate MCP servers from the catalog to get tools.',
      'Follow these phases IN ORDER. Do not skip phases.',
      '',
      'PHASE 1 — Bootstrap:',
      '  You have no shell yet! First get your tools:',
      '  Use raider_manage_mcps action "list" to see available MCP servers.',
      '  Use raider_manage_mcps action "activate" name "shell" to get the run tool.',
      '  Use raider_manage_mcps action "activate" name "notes" to get save_note/read_notes.',
      '',
      'PHASE 2 — Recon:',
      '  Now you have a shell. Run: uname -a',
      '  Run: ls',
      '  Run: wc -l lib/Langertha.pm',
      '',
      'PHASE 3 — Wait for build:',
      '  A background build is already running.',
      '  Use raider_wait for 3 seconds, reason "waiting for background build".',
      '  Use raider_wait_for condition "file_exists" args {"path":"/tmp/raider_build_report.txt"}.',
      '  Run: cat /tmp/raider_build_report.txt',
      '',
      'PHASE 4 — Switch engines and take notes:',
      '  Use raider_switch_engine name "fast" to switch to the fast model.',
      '  Use save_note to record the build result.',
      '  Use raider_switch_engine name "smart" to switch back.',
      '',
      'PHASE 5 — Ask user:',
      '  Use raider_ask_user question "Build succeeded. Should I run the tests too?"',
      '  Do what the user says.',
      '',
      'PHASE 6 — Review and report:',
      '  Use raider_session_history with last_n 5 to review recent activity.',
      '  Use read_notes to review your notebook.',
      '  Give a concise final status report.',
    ),
    on_ask_user => sub {
      my ($question, $options) = @_;
      sep();
      printf "  %s\n", colored('35', '[SELF-TOOL] raider_ask_user');
      info("  Q: $question");
      if ($options && @$options) {
        info("  Options: " . join(', ', @$options));
      }
      my $answer = $simulated_answers[$answer_idx] // "Wrap it up.";
      $answer_idx++;
      printf "  %s %s\n", colored('32', '  >>> Demo user:'), $answer;
      sep();
      return $answer;
    },
    on_wait_for => sub {
      my ($condition, $args) = @_;
      sep();
      printf "  %s\n", colored('35', '[SELF-TOOL] raider_wait_for');
      printf label("  condition", $condition);
      if ($args) {
        for my $k (sort keys %$args) {
          printf label("  $k", $args->{$k});
        }
      }
      if ($condition eq 'file_exists') {
        my $path = $args->{path} // '';
        my $exists = -f $path;
        my $msg = $exists ? "File exists: $path" : "File not found yet: $path";
        printf label("  result", $exists ? colored('32', $msg) : colored('33', $msg));
        sep();
        return $msg;
      }
      sep();
      return "Unknown condition: $condition";
    },
    on_iteration => sub {
      my ($raider, $iteration) = @_;

      # Detect engine changes
      my $cur_engine = $raider->engine_info->{name} // 'default';
      my $cur_model  = $raider->active_engine->chat_model;
      if ($cur_engine ne $prev_engine) {
        printf "\n  %s %s -> %s (%s)\n",
          colored('35', '[ENGINE SWITCH]'),
          colored('90', $prev_engine),
          colored('32', $cur_engine),
          $cur_model;
        $prev_engine = $cur_engine;
      }

      # Detect MCP catalog changes
      my %cur_active;
      for my $name (keys %{$raider->mcp_catalog}) {
        $cur_active{$name} = 1 if exists $raider->_active_catalog_mcps->{$name};
      }
      for my $name (keys %cur_active) {
        unless ($prev_active_mcps{$name}) {
          printf "  %s %s activated\n",
            colored('35', '[MCP CATALOG]'), colored('32', $name);
        }
      }
      for my $name (keys %prev_active_mcps) {
        unless ($cur_active{$name}) {
          printf "  %s %s deactivated\n",
            colored('35', '[MCP CATALOG]'), colored('33', $name);
        }
      }
      %prev_active_mcps = %cur_active;

      # Show iteration header with full state
      printf "\n  %s\n", colored('1', "=== ITERATION $iteration ===");
      show_state($raider);

      sleep 0.8;  # rate limit protection
      return;
    },
  );

  # ── 10. Raid ──

  banner("RAID: Full-Stack Build Engineer");
  info("Initial state:");
  show_state($raider);

  my $result = await $raider->raid_f(
    'Start the build engineer workflow. Follow all phases in your mission.'
  );

  # ── 11. Results ──

  printf "\n";
  banner("FINAL ANSWER");
  if ($result->is_final) {
    printf "%s\n", $result;
  } elsif ($result->is_question) {
    info("[RESULT] question: ${\$result->content}");
  } elsif ($result->is_pause) {
    info("[RESULT] pause: ${\$result->content}");
  } elsif ($result->is_abort) {
    info("[RESULT] abort: ${\$result->content}");
  }

  # ── 12. Metrics ──

  banner("METRICS");
  my $m = $raider->metrics;
  info(sprintf "Raids:      %d", $m->{raids});
  info(sprintf "Iterations: %d", $m->{iterations});
  info(sprintf "Tool calls: %d", $m->{tool_calls});
  info(sprintf "Total time: %.1f s", $m->{time_ms} / 1000);

  # ── 13. Notebook ──

  if (@notebook) {
    banner("NOTEBOOK (saved by LLM via notes MCP)");
    for my $note (@notebook) {
      info("[$note->{title}] $note->{text}");
    }
  }

  # ── 14. Session history ──

  banner("SESSION HISTORY");
  my @hist = @{$raider->session_history};
  for my $i (0 .. $#hist) {
    my $msg = $hist[$i];
    my $role = $msg->{role} // '?';
    my $content = $msg->{content} // '';
    if (ref $content eq 'ARRAY') {
      $content = join(' ', map {
        $_->{text} // "[" . ($_->{type} // '?') . "]"
      } @$content);
    }
    $content =~ s/\n/ /g;
    $content = substr($content, 0, 120) . '...' if length($content) > 120;
    printf "  %s %-10s %s\n", colored('90', sprintf('%02d', $i + 1)), $role, $content;
  }
  info("");
  info(sprintf "Session: %d messages | History: %d messages",
    scalar @hist, scalar @{$raider->history});

  # Cleanup
  unlink $report_file;
}

main()->get;
