#!/usr/bin/perl -w
#
# Copyright 2003 Brian Caswell <bmc@snort.org>
# All rights reserved.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#

use strict;
use vars qw($VERSION);
use Curses::Application;
use POSIX;
use IPC::Open2;
use IO::Select;

#####################################################################
#
# Set up the environment
#
#####################################################################

my $s = IO::Select->new();
my ($wtr, $rdr, $pid);
my $need_save = 1;
my $scanning  = 0;

$SIG{CHLD} = sub {
	if ($scanning eq 1) {
		check_data();
		start_scan();
	}
	elsif ($scanning eq 1) {
		check_data();
		start_scan_brute();
	} else {
		$scanning = 0; 
	}
};
$SIG{PIPE} = sub { 
	$scanning = 0; 
};

($VERSION) = (q$Revision: 0.1 $ =~ /(\d+[^ ]*) /);

my $app = Curses::Application->new(
   {
      FOREGROUND => 'white',
      BACKGROUND => 'black',
      CAPTIONCOL => 'cyan',
      TITLEBAR   => 1,
      CAPTION    => "Bluetooth Scanner $VERSION",
      MAINFORM   => {Main => 'MainFrm'},
      INPUTFUNC  => \&myscankey,
   }
);

my ($rv, $f, $w);

# bluetooth database
#
# mac => { 
#   date_last       => timestamp
#   date_first      => timestamp
#   name            => data
#   version         => data
#   manufacturer    => data
#   features        => data
#   class           => data
#   signal_strength => data
#   link_quality    => data
#   }

my %records = (
   '00:80:98:00:1E:41' => {
      date_last       => 1158146971,
      date_first      => 1058146971,
      name            => 'lame device',
      version         => '1.1',
      manufacturer    => 'cisco',
      features        => 'none',
      class           => 'phone',
      signal_strength => 80,
      link_quality    => 33,
   },
   '00:80:98:02:1E:41' => {
      date_last       => 1058142971,
      date_first      => 1008116971,
      name            => 'other lame device',
      version         => '2.1',
      manufacturer    => 'linksys',
      features        => 'all',
      class           => 'palm',
      signal_strength => 10,
      link_quality    => 100,
   },
);

my %need_info;

# Draw the main screen
$app->draw;

# Create the MainFrm early, since we need to adjust a few parameters
# of the ListBox and Label
$app->createForm(qw(Main MainFrm));
$w = $app->getForm('Main')->getWidget('Devices');
$w->setField(
   LINES     => ($app->maxyx)[0] - 7,
   LISTITEMS => [map { [split (', ', $_)] } sort keys %records],
);
$w = $app->getForm('Main')->getWidget('Message');
$w->setField(VALUE => << '__EOF__');
<ESC> to cancel the drop-down menu
<TAB> to move among the widgets
<ENTER> to view details of the device
Use arrows for scrolling
__EOF__

# Start the input loop
$app->execute;

exit 0;

#####################################################################
#
# Subroutines follow here
#
#####################################################################

sub myscankey {
   my $mwh = shift;
   my $key = -1;

   while ($key eq -1) {
      check_data();
      draw_clock();
      get_info();
      $key = $mwh->getch();
   }

   return $key;

}

sub check_data {

   # warn "Check data $scanning\n";
   if ($scanning ne 0) {
      my @ready = $s->can_read(1);
      foreach (@ready) {
         my $data;
         sysread($_, $data, 10000);
         chomp($data);
         while ($data =~ s/^\s+([^\s]*)\s+(.*)//m) {
            my $mac  = $1;
            my $name = $2;

            if (!defined($records{$mac})) {
               $records{$mac}{'date_first'} = time();
               $need_info{$mac} = 1;
               $records{$mac}{'version'}         = "";
               $records{$mac}{'manufacturer'}    = "";
               $records{$mac}{'features'}        = "";
               $records{$mac}{'class'}           = "";
               $records{$mac}{'signal_strength'} = 0;
               $records{$mac}{'link_quality'}    = 0;
            }
            $records{$mac}{'date_last'} = time();
            $records{$mac}{'name'}      = $name;
            my $f = $app->getForm('Main');
            my $w = $f->getWidget('Devices');
            $w->setField(
               LISTITEMS => [map { [split (', ', $_)] } sort keys %records]);
         }
      }
   }
}

sub draw_clock {
   my $time = scalar localtime;
   if ($scanning eq 1) {
      $time = "            (Scanning) " . $time;
   }
   if ($scanning eq 2) {
      $time = "(Brute Force Scanning) " . $time;
   }
   my $x       = ($app->maxyx)[1] - length($time);
   my $caption = substr($app->getField('CAPTION'), 0, $x);

   $caption .= ' ' x ($x - length($caption)) . $time;
   $app->setField(CAPTION => $caption);
   $app->draw;
}

sub save {
   $need_save = 0;
   dialog('Save Database', BTN_OK,
      'yeah, it would be nice if I bothered to write this...',
      qw(white black red));
}

sub get_info {
   if (keys %need_info) {
      my $old_scanning = $scanning;
      foreach my $mac (keys %need_info) {

         # warn "Checking $mac\n";

         if ($pid) {
            kill(9, $pid);
            $s->remove($rdr);
         }

         $pid = open2($rdr, $wtr, "hcitool info $mac");
         $s->add($rdr);
         $scanning = 1;
         while ($scanning eq 1) {

            my @ready = $s->can_read(0);
            foreach (@ready) {
               my $data;
               sysread($_, $data, 10000);
               chomp($data);
               if ($data =~ /^\tDevice Name: (.*)/m) {
                  $records{$mac}{'name'} = $1;
               }

               if ($data =~ /^\tLMP Version: (.*) LMP Subversion/m) {
                  $records{$mac}{'version'} = $1;
               }

               if ($data =~ /^\tManufacturer: (.*)/m) {
                  $records{$mac}{'manufacturer'} = $1;
               }

               if ($data =~ /^\tFeatures: (.*)/m) {
                  $records{$mac}{'features'} = $1;
               }
               delete($need_info{$mac});
               $scanning = 0;
            }
         }

         if ($pid) {
            kill(9, $pid);
            $s->remove($rdr);
         }

         $pid = open2($rdr, $wtr, "hcitool lq $mac");
         $s->add($rdr);
         $scanning = 1;
         while ($scanning eq 1) {
            my @ready = $s->can_read(0);
            foreach (@ready) {
               my $data;
               sysread($_, $data, 10000);
               chomp($data);
               if ($data =~ /^Blah: (\d+)/m) {
                  my $lq = $1;
                  $lq = int(($lq * 100) / 255);
                  $records{$mac}{'link_quality'} = $lq;
               }
               $scanning = 0;
            }
         }

         if ($pid) {
            kill(9, $pid);
            $s->remove($rdr);
         }
         $pid = open2($rdr, $wtr, "hcitool rssi $mac");
         $s->add($rdr);
         $scanning = 1;
         while ($scanning eq 1) {
            my @ready = $s->can_read(0);
            foreach (@ready) {
               my $data;
               sysread($_, $data, 10000);
               chomp($data);
               if ($data =~ /^Blah: (\d+)/m) {
                  my $rssi = $1;
                  $rssi = int(($rssi * 100) / 255);
                  $records{$mac}{'signal_strength'} = $rssi;
               }
               $scanning = 0;
            }
         }

         if ($pid) {
            kill(9, $pid);
            $s->remove($rdr);
         }

      }

      if ($old_scanning eq 1) {
         $pid = open2($rdr, $wtr, 'hcitool scan');
         $s->add($rdr);
      } elsif ($old_scanning eq 2) {
         $pid = open2($rdr, $wtr, 'hcitool scan');
         $s->add($rdr);
      }
   }
}

sub scan {
   start_scan();
   dialog(
      'Scanning',                        BTN_OK,
      'Starting scanning (normal mode)', qw(white black red)
   );
}

sub start_scan {
   $scanning = 1;
   if ($pid) {
      kill(9, $pid);
      $s->remove($rdr);
   }
   $pid = open2($rdr, $wtr, 'hcitool scan');
   $s->add($rdr);
}

sub scan_brute {
   start_scan_brute();
   dialog(
      'Scanning',                             BTN_OK,
      'Starting scanning (brute force mode)', qw(white black red)
   );
}

sub start_scan_brute {
   $scanning = 2;
   if ($pid) {
      kill(9, $pid);
      $s->remove($rdr);
   }
   $pid = open2($rdr, $wtr, 'hcitool scan');
   $s->add($rdr);
}

sub quit {
   if ($need_save) {
      $rv =
        dialog('Quit Application?', BTN_YES | BTN_NO,
         "You havn't saved yet.  Are you sure you want to quit?",
         qw(white red yellow));
      exit 0 unless ($rv);
   } else {
      kill(9, $pid);
      exit;
   }
}

sub displayrec {
   my $f   = shift;
   my $key = shift;
   my ($w, $list, $rec, @items);

   return unless $key =~ /[\n ]/;

   # Get the list box widget to retrieve the select record
   $w     = $f->getWidget('Devices');
   @items = @{$w->getField('LISTITEMS')};
   $rec   = $items[$w->getField('CURSORPOS')];
   $rec   = @$rec[0];

   if (defined($rec) && defined($records{$rec})) {
      foreach my $item (qw(name version manufacturer features class)) {
         my $w = $f->getWidget($item);
         $w->setField(VALUE => $records{$rec}{$item});
      }

      foreach my $item (qw(date_last date_first)) {
         my $w = $f->getWidget($item);
         $w->setField(
            VALUE => strftime("%Y-%m-%d %T", localtime($records{$rec}{$item})));
      }

      foreach my $item (qw(signal_strength link_quality)) {
         my $data   = $records{$rec}{$item};
         my $size   = ($data / 100) * 25;
         my $string = "#" x $size;
         $string .= " " x (25 - $size);
         my $text   = "$data\%";
         my $offset = (25 / 2) - length($text) + 2;
         $string =
           substr($string, 0, $offset) . $text . substr($string, $offset, 25);

         my $w = $f->getWidget($item);
         $w->setField(VALUE => $string);
      }

   }

   # Set the form's DONTSWITCH directive to keep the focus where it is
   $f->setField(DONTSWITCH => 1);
}

sub delrec {
   my $f   = $app->getForm('Main');
   my $w   = $f->getWidget('Devices');
   my $rec = ${$w->getField('LISTITEMS')}[$w->getField('CURSORPOS')];

   # Delete the record from the hash and list box
   delete $records{@$rec[0]};
   $w->setField(LISTITEMS => [map { [split (', ', $_)] } sort keys %records]);

   # Reset the form fields
   resetfields($f);
}

sub resetfields {
   my $f = shift;

   # Reset the displayed record field
   foreach (
      qw(date_last date_first name version manufacturer features class signal_strength link_quality)
     )
   {
      $f->getWidget($_)->setField(VALUE => '');
   }
}

__DATA__

%forms = (
  MainFrm     => {
    TABORDER        => [qw(Menu Devices)],
    FOCUSED         => 'Devices',
    WIDGETS         => {
      Menu            => {
        TYPE            => 'Menu',
        MENUS           => {
          MENUORDER       => [qw(File Record Scan)],
          File            => {
            ITEMORDER       => [qw(Save Exit)],
            Exit            => \&main::quit,
            Save            => \&main::save,
            },
          Record            => {
            ITEMORDER       => ['Delete Device'],
            'Delete Device' => \&main::delrec,
            },
          Scan => {
                ITEMORDER       => ['Normal Scan','Brute Force Scan'],
                'Normal Scan' => \&main::scan,
                'Brute Force Scan' => \&main::scan_brute,
            },
          },
        },
      Devices => {
        TYPE            => 'ListBox::MultiColumn',
        LISTITEMS       => [],
        COLUMNS         => 17,
        LINES           => 10,
        Y               => 2,
        X               => 1,
        COLWIDTHS       => [17],
        HEADERS         => [("HW Address")],
        BIGHEADER       => 1,
        CAPTION         => 'Devices',
        FOCUSSWITCH     => "\t\n ",
        OnExit          => \&main::displayrec,
        },
      date_last => {
        TYPE            => 'TextField',
        Y               => 2,
        X               => 21,
        CAPTION         => 'Last Seen',
        COLUMNS         => 25,
        },
      date_first => {
        TYPE            => 'TextField',
        Y               => 2,
        X               => 48,
        CAPTION         => 'First Seen',
        COLUMNS         => 25,
        },
      name => {
        TYPE            => 'TextField',
        Y               => 5,
        X               => 21,
        CAPTION         => 'Device Name',
        COLUMNS         => 52,
        },
      version => {
        TYPE            => 'TextField',
        Y               => 8,
        X               => 21,
        CAPTION         => 'Version',
        COLUMNS         => 20,
        },
      manufacturer => {
        TYPE            => 'TextField',
        Y               => 8,
        X               => 43,
        CAPTION         => 'Manufacturer',
        COLUMNS         => 30,
        },
      class => {
        TYPE            => 'TextField',
        Y               => 11,
        X               => 21,
        CAPTION         => 'Class',
        COLUMNS         => 25,
        },
      features => {
        TYPE            => 'TextField',
        Y               => 11,
        X               => 48,
        CAPTION         => 'Features',
        COLUMNS         => 25,
        },
      signal_strength => {
        TYPE            => 'TextField',
        Y               => 14,
        X               => 21,
        CAPTION         => 'Signal Strength',
        COLUMNS         => 25,
        },
      link_quality => {
        TYPE            => 'TextField',
        Y               => 14,
        X               => 48,
        CAPTION         => 'Link Quality',
        COLUMNS         => 25,
        },
      Message         => {
        TYPE            => 'Label',
        CENTER          => 1,
        Y               => 17,
        X               => 26,
        COLUMNS         => 42,
        LINES           => 6,
        ALIGNMENT       => 'C',
        },
      },
    },
  );

