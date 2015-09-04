#! /usr/bin/perl -w

# deb-rebuild

use warnings;

use AptPkg::Config '$_config';
use AptPkg::System '$_system';
use AptPkg::Source;
use AptPkg::Cache;

$_config->init();
$_system = $_config->system();
my $cache    = AptPkg::Cache->new();
my $source   = AptPkg::Source->new();
my $_version = $_system->versioning;

my $dtypes = "Depends";
my %pstatus;
my @packlist = ();

my $bdir = "/root/r";

# Translates AptPkg's (localized) dependency types to what's used by debtree.
# This is only needed for regular dependencies, not build dependencies.
sub get_type {
	my $apt_dtype = shift;
	return "PreDepends" if ( $apt_dtype == AptPkg::Dep::PreDepends );
	return "Depends"    if ( $apt_dtype == AptPkg::Dep::Depends );
	return "Recommends" if ( $apt_dtype == AptPkg::Dep::Recommends );
	return "Suggests"   if ( $apt_dtype == AptPkg::Dep::Suggests );
	return "Conflicts"  if ( $apt_dtype == AptPkg::Dep::Conflicts );
	return "Unsupported";
}

sub preprocess_deps {
	my $package = shift;
	my $pinfo   = shift;

	my $dtype = "";
	my $delim = "";
	my $deps  = "";

	$pstatus{$package}{done} = 1;
	return unless exists $$pinfo{DependsList};
	for my $dep ( @{ $$pinfo{DependsList} } ) {
		my $p = $$dep{TargetPkg};

		if (
			$$dep{DepType} eq "Depends"
			and (   $$p{Name} ne "libc6"
				and $$p{Name} ne "libgcc1"
				and $$p{Name} ne "libstdc++6" )
		  )
		{
			print "$level : $package -> $$p{Name}\n";
			if ( $pstatus{ $$p{Name} }{done} != 1 ) {
				$ppinfo = get_apt_pinfo( $$p{Name}, "B" );
				@packlist = ( @packlist, $$p{Name} );
				++$level;
				preprocess_deps( $$p{Name}, $ppinfo );
			}
		}
	}
	--$level;
}

sub get_apt_pinfo {
	my ( $package, $ptype ) = @_;

	my $pdata = $cache->get($package);
	return unless $pdata;
	if ( exists $$pdata{VersionList} ) {

		# First in array is highest version
		return shift( @{ $$pdata{VersionList} } );
	}
}

sub get_src_name {
	my ( $pkg_name, $src_version ) = @_;
	my $src_name;
	foreach ( @{ $source->{$pkg_name} } ) {
		$src_name = $_->{Package} if ( $src_version eq $_->{Version} );
	}

	return $src_name;
}

sub get_src_version {
	my $pkg_name    = $_[0] || die;
	my $pkg_version = $_[1] || &get_pkg_version($pkg_name);
	my $src_version;

	# By default
	$src_version = $pkg_version;

	open APTCIN, "LANGUAGE=C " . "apt-cache" . " show $pkg_name=$pkg_version |";
	while (<APTCIN>) {
		if (/^Source: (.*)\((.*)\)/) {
			$src_version = $2;
			last;
		}
	}
	close(APTCIN);

	return $src_version;
}

sub get_pkg_version {
	my $pkg_name = shift;
	my $release = shift || "";
	my $pkg_version;

	# Look for candidate version
	open APTCIN, "LANGUAGE=C " . "apt-cache" . " policy $pkg_name |";
	while (<APTCIN>) {
		$pkg_version = $1 if ( /^\s+Candidate: (.*)$/ and $release eq "" );
		if ($release) {
			last
			  if (/$release/)
			  ;    ## quit from while,but keep the version from the row before
			$pkg_version = $2 if (/^\s(\*\*\*)?\s+(.*) \d/);
		}
	}
	close(APTCIN);

	# In case we fail to find a valid candidate, which may happen if,
	# for example, the package has no binary version but a source
	# version, we fall back to the source version in order to avoid
	# dying.
	if ( !$pkg_version ) {
		open APTCIN, "LANGUAGE=C " . "apt-cache" . " showsrc $pkg_name |";
		while (<APTCIN>) {
			$pkg_version = $1 if ( /^Version: (.*)$/ and $release eq "" );
			if ($release) {
				last
				  if (/$release/)
				  ;  ## quit from while,but keep the version from the row before
				$pkg_version = $2 if (/^\s(\*\*\*)?\s+(.*) \d/);
			}
		}
		close(APTCIN);
	}
	die "Unable to find source candidate for $pkg_name\n" unless ($pkg_version);

	return $pkg_version;
}

sub build_deb_filename {
	my ( $pkg_name, $pkg_version ) = @_;
	my $deb_file;

	# set host architecture as default value
	my $arch = `dpkg --print-architecture`;
	chomp $arch;

	# Build the .deb name
	open APTCIN, "LANGUAGE=C " . "apt-cache" . " show $pkg_name=$pkg_version |";
	while (<APTCIN>) {
		$arch = $1 if (/^Architecture: (.*)/);
	}
	close(APTCIN);

	my $pkg_version_file;
	$pkg_version_file = $pkg_version;

	# dpkg-buildpackage doesn't put epoch in file name, so remove it.
	$pkg_version_file =~ s/^\d://;
	$deb_file = $pkg_name . "_" . $pkg_version_file . "+atom_" . $arch . ".deb";
}

sub uniq {
	my %seen;
	grep !$seen{$_}++, @_;
}

sub read_apt_list {
	my ( $line, $pattern, $handler ) = @_;
	my @results;
	open IN, "$line";
	while ( local $_ = <IN> ) {
		if (/$pattern/i) { local $_ = &$handler(); push @results, $_ if $_ }
	}
	close IN;
	return @results;
}

sub extract_name { ( $_ = ( split /\s+/ )[1] ) =~ s/_.*// if /_/; $_ }

sub extract_filename { return ( split /\s+/ )[1] }

sub extract_size { return ( split /\s+/ )[2] }

sub apt_args_modify {
	my ( $self, $name, $value ) = @_;

	if ( !( $self->{ARGCOUNT}->{$name} ) )    # if option takes no argument
	{
		$name =~ s|\_|\-|g;
		if ($value) { push @apt_args, "--$name" }
		else {
			@apt_args = grep { !/^--$name$/ } @apt_args;
		}

	}
	elsif ( $self->{ARGCOUNT}->{$name} == ARGCOUNT_ONE )    # or if takes 1 arg
	{
		@apt_args = grep { !/^--$name / } @apt_args;        # just to be sure

		# special parsing for --sources-list
		# that is now deprecated because Dir::Etc::SourceList and
		# Dir::Etc::sourceparts is already in use
		if ( $name =~ /^sources.list$/ ) {
			$name = "-oDir::Etc::SourceList=$value";
		}
		else { $name = "--$name $value"; }

		push @apt_args, "$name";

	}
}

sub builddep {
	my $pkg = shift or return;
	my $pkg_version = $_[0] || &get_pkg_version($pkg);

	print STDERR
	  "-----> Installing build dependencies (for $pkg=$pkg_version) <-----";
	!system "sudo apt-get -y --force-yes" . " @apt_args build-dep $pkg=$pkg_version";
}

sub source_by_package {
	my $pkg_name = shift
	  or return;
	my ( $pkg_version, $src_version, $src_name );

	if ( !( $src_version = shift ) ) {
		# no version passed along.
		$src_version = &get_src_version($pkg_name);
	}

	$src_name = &get_src_name( $pkg_name, $src_version );

	return source_by_source( $src_name, $src_version );
}

sub source_by_source {
	my $src_name = $_[0]
	  or return;
	my $src_version = $_[1]
	  or return;

	print STDERR "-----> Downloading source $src_name ($src_version) <-----";
	return !system "apt-get " . " @apt_args source ${src_name}=${src_version}";
}

sub patch {
	print STDERR "-----> Patching (@_) <-----";
	!system "patch -p$conf{patch_strip} < $_" or return !$? while $_ = shift;
	return 1;
}

my $cflags =
"\"-O2 -mtune=bonnell -march=bonnell -mfpmath=sse -ffast-math -fomit-frame-pointer\"";
my $deb_build_options = "\"nocheck parallel=4\"";

sub build {
	@_ == 3 or return;
	my ( $src_name, $upver, $maintver ) = @_;
	my ( $src_version, $control, @packages, $srcpkg, $srcver, $upverchdir,
		$new );

	print STDERR "-----> Building $src_name <-----\n";

	$upver =~ s/^\d+://;    # strip epoch

	chdir $bdir;

	chdir "$src_name-$upver";

	# Add an entry in changelog
	system "debchange --local +bonnell --distribution wily 'Built by mydebtools'";

	my $r = 1;

	if ($r) {

		$ENV{'DEB_BUILD_OPTIONS'} = 'nocheck';
		$ENV{'DEB_CFLAGS'} = $cflags;
		$ENV{'DEB_CXXFLAGS'} = $cflags;
		$ENV{'LANGUAGE'} = 'C';
		# Now build
		$r = !system "dpkg-buildpackage";
		wait;
	}

	print STDERR "----> Cleaning up object files <-----";
	system "debclean";
	wait;

	#    chdir $conf{build_dir};
	chdir $bdir;
	return $r;
}

sub touch {
	my $fname = shift;
	unless ( -f $fname ) {
		my $f = new IO::File( $fname, "a" ) || die "open: $!";
		$f->close();
	}

	my $now = time();
	utime( $now, $now, $fname ) || die "utime: $!";
}

$ENV{'LANGUAGE'} = 'C';

chdir $bdir;

my $package = shift or die;

system "sudo apt-get update";

print "processing $package : ";
$pinfo = get_apt_pinfo( $package, "B" );
print "$$pinfo{VerStr}\n";

$level    = 0;
@packlist = ($package);
preprocess_deps( $package, $pinfo );

print "packlist = @packlist\n";
my $pcount = @packlist;
print "found $pcount packages for $package\n";

my @pkgs    = ();
my @srclist = ();
for my $pkg_name (@packlist) {
	print "** $pkg_name\n";
	my $pkg_version = &get_pkg_version($pkg_name);
	if ($pkg_version eq '(none)') {
		print "$pkg_name might be virtual : skipping\n";
		next;
	}
	
	my $src_version = &get_src_version( $pkg_name, $pkg_version );
	my $src_name    = &get_src_name( $pkg_name, $src_version );
	if ( !$src_name && $src_version =~ /\+/ ) {
		$src_version =~ s/\+.*$//;
		$src_name = &get_src_name( $pkg_name, $src_version );
	}
	if ($src_name && pkg_version ne 'none') {
		push( @srclist, $src_name );
	}
}

my @blist  = uniq(@srclist);
my $bcount = @blist;

print "$bcount packages to build : @blist\n";

for my $pkg_name (@blist) {
	my $pkg_version = &get_pkg_version($pkg_name);
	my $src_version = &get_src_version( $pkg_name, $pkg_version );
	my $src_name    = &get_src_name( $pkg_name, $src_version );
	if ( !$src_name && $src_version =~ /\+/ ) {
		$src_version =~ s/\+.*$//;
		$src_name = &get_src_name( $pkg_name, $src_version );
	}
	$deb_file_name = build_deb_filename( $pkg_name, $pkg_version );
	print "$deb_file_name\n";
	push @pkgs, $deb_file_name;
	if ( -f "$bdir/$deb_file_name.built" ) {
		print "$deb_file_name Already built\n";
	}
	else {
		builddep( $src_name, $src_version );
		source_by_package( $pkg_name, $src_version );
		my $upver = $_version->upstream($src_version);
		my $maintver = $1 if $src_version =~ /^$upver-(.*)$/;
		touch("$deb_file_name.built");
		if(!build( $src_name, $upver, $maintver ))
		{
			print "$pkg_name : BUILD FAILED\n";
			unlink("$deb_file_name.built");
			touch("$deb_file_name.failed");
		}
	}
}

print "exiting\n";
