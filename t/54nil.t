#!/usr/bin/perl

use warnings;
use strict;

use lib 'lib','t';
use TestTools;

use XML::Compile::Schema;
use XML::Compile::Tester;

use Test::More tests => 42;

my $schema   = XML::Compile::Schema->new( <<__SCHEMA__ );
<schema targetNamespace="$TestNS"
        xmlns="$SchemaNS"
        xmlns:me="$TestNS">

<element name="test1">
  <complexType>
    <sequence>
      <element name="e1" type="int" />
      <element name="e2" type="int" nillable="true" />
      <element name="e3" type="int" />
    </sequence>
  </complexType>
</element>

</schema>
__SCHEMA__

ok(defined $schema);

set_compile_defaults check_occurs => 1
                   , invalid      => 'WARN';

#
# simple element type
#

test_rw($schema, test1 => <<__XML__, {e1 => 42, e2 => 43, e3 => 44} );
<test1><e1>42</e1><e2>43</e2><e3>44</e3></test1>
__XML__

test_rw($schema, test1 => <<__XML__, {e1 => 42, e2 => 'NIL', e3 => 44} );
<test1><e1>42</e1><e2 nil="true"/><e3>44</e3></test1>
__XML__

my %t1c = (e1 => 42, e2 => 'NIL', e3 => 44);
test_rw($schema, test1 => <<__XML__, \%t1c, <<__XMLWriter);
<test1><e1>42</e1><e2 nil="1" /><e3>44</e3></test1>
__XML__
<test1><e1>42</e1><e2 nil="true"/><e3>44</e3></test1>
__XMLWriter

{   my $error = reader_error($schema, test1 => <<__XML__);
<test1><e1></e1><e2 nil="true"/><e3>45</e3></test1>
__XML__
   is($error,"illegal value `' for type {http://www.w3.org/2001/XMLSchema}int");
}

{   my %t1b = (e1 => undef, e2 => undef, e3 => 45);
    my $error = writer_error($schema, test1 => \%t1b);

    is($error, "required value for `e1' missing at {http://test-types}test1");
}

{   my $error = reader_error($schema, test1 => <<__XML__);
<test1><e1>87</e1><e3>88</e3></test1>
__XML__
    is($error, "data for element or block starting with `e2' missing at {http://test-types}test1");
}

#
# fix broken specifications
#

set_compile_defaults interpret_nillable_as_optional => 1;

my %t1d = (e1 => 89, e2 => undef, e3 => 90);
my %t1e = (e1 => 91, e2 => 'NIL', e3 => 92);
my $error = test_rw($schema, test1 => <<__XML, \%t1d, <<__XML, \%t1e);
<test1><e1>89</e1><e3>90</e3></test1>
__XML
<test1><e1>91</e1><e3>92</e3></test1>
__XML
