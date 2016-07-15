 
package XML::Compile::Translate::Writer;
use base 'XML::Compile::Translate';

use strict;
use warnings;
no warnings 'once', 'recursion';

use Log::Report   qw/xml-compile/;
use List::Util    qw/first/;
use Scalar::Util  qw/blessed weaken/;
use XML::Compile::Util qw/pack_type unpack_type type_of_node SCHEMA2001i
  SCHEMA2001 odd_elements even_elements/;

use XML::LibXML;
use Encode        qw/encode/;

=chapter NAME

XML::Compile::Translate::Writer - translate HASH to XML

=chapter SYNOPSIS

 my $schema = XML::Compile::Schema->new(...);
 my $code   = $schema->compile(WRITER => ...);

=chapter DESCRIPTION
The translator understands schemas, but does not encode that into
actions.  This module implements those actions to translate from
a (nested) Perl HASH structure onto XML.

=chapter METHODS

=cut

# Each action implementation returns a code reference, which will be
# used to do the run-time work.  The principle of closures is used to
# keep the important information.  Be sure that you understand closures
# before you attempt to change anything.
#
# The returned writer subroutines will always be called
#       $writer->($doc, $value) 

sub actsAs($) { $_[1] eq 'WRITER' }

sub makeTagQualified
{ # my ($self, $path, $node, $local, $ns) = @_;
  # my $prefix = $self->_registerNSprefix('', $ns, 1);
  # length($prefix) ? "$prefix:$local" : $local;
    my $prefix = $_[0]->_registerNSprefix('', $_[4], 1);
    length($prefix) ? "$prefix:$_[3]" : $_[3];
}

sub makeTagUnqualified
{ # my ($self, $path, $node, $local, $ns) = @_;
  # $local;
    $_[3];
}

sub _typemapClass($$)
{   my ($self, $type, $class) = @_;

    no strict 'refs';
    keys %{$class.'::'}
        or error __x"class {pkg} for typemap {type} is not loaded"
             , pkg => $class, type => $type;

    $class->can('toXML')
        or error __x"class {pkg} does not implement toXML(), required for typemap {type}"
             , pkg => $class, type => $type;

    sub {
        my ($doc, $values, $path) = @_;
        UNIVERSAL::isa($values, $class) ? $values->toXML($type, $doc) : $values;
    };
}

sub _typemapObject($$)
{   my ($self, $type, $object) = @_;

    $object->can('toXML')
        or error __x"object of class {pkg} does not implement toXML(), required for typemap {type}"
             , pkg => ref($object), type => $type;

    sub {
        my ($doc, $values, $path) = @_;
        blessed($values) ? $object->toXML($values, $type, $doc) : $values;
    };
}

sub typemapToHooks($$)
{   my ($self, $hooks, $typemap) = @_;
    while(my($type, $action) = each %$typemap)
    {   defined $action or next;
        my $hook;
        if(!ref $action)
        {   $hook = $self->_typemapClass($type, $action);
            trace "created writer hook for type $type to class $action";
        }
        elsif(ref $action eq 'CODE')
        {   $hook = sub {
               my ($doc, $values, $path) = @_;
                 blessed($values)
               ? $action->(WRITER => $values, $type, $doc)
               : $values;
            };
            trace "created writer hook for type $type to CODE";
        }
        else
        {   $hook = $self->_typemapObject($type, $action);
            trace "created reader hook for type $type to object";

        }

        push @$hooks, +{action => 'WRITER', type => $type, before => $hook};
    }
    $hooks;
}

sub makeElementWrapper
{   my ($self, $path, $processor) = @_;
    sub {
        my ($doc, $data) = @_;
        UNIVERSAL::isa($doc, 'XML::LibXML::Document')
            or error __x"first argument of call to writer must be an XML::LibXML::Document";


        my $top = $processor->(@_);
        $doc->indexElements;
        $top;
    };
}
*makeAttributeWrapper = \&makeElementWrapper;

sub makeWrapperNs
{   my ($self, $path, $processor, $index, $filter) = @_;
    my @entries;
    $filter = sub {$_[2]} if ref $filter ne 'CODE'; # only the used

    foreach my $entry (sort {$a->{prefix} cmp $b->{prefix}} values %$index)
    {   # ANY components are frustrating this
        $filter->($entry->{uri}, $entry->{prefix}, $entry->{used}) or next;
        push @entries, [ $entry->{uri}, $entry->{prefix} ];
        $entry->{used} = 0;
    }

    @entries or return $processor;

    sub {
        my $node = $processor->(@_) or return ();
        UNIVERSAL::isa($node, 'XML::LibXML::Element')
            or return $node;
        $node->setNamespace(@$_, 0) for @entries;
        $node;
    };
}

sub makeSequence($@)
{   my ($self, $path, @pairs) = @_;

    if(@pairs==2)
    {   my ($take, $do) = @pairs;

        return
            ref $do eq 'ANY'   ? bless(sub { $do->(@_) }, 'BLOCK')
          : ref $do eq 'BLOCK' ? $do
          : bless sub {
                my ($doc, $values) = @_;
                defined $values or return;
                $do->($doc, delete $values->{$take});
            }, 'BLOCK';
    }
 
    bless sub {
        my ($doc, $values) = @_;
        defined $values or return;

        my @res;
        my @do = @pairs;
        while(@do)
        {   my ($take, $do) = (shift @do, shift @do);
            push @res
               , ref $do eq 'BLOCK' ? $do->($doc, $values)
               : ref $do eq 'ANY'   ? $do->($doc, $values)
               : $do->($doc, delete $values->{$take});
        }
        @res;
      }, 'BLOCK';
}

sub makeChoice($@)
{   my ($self, $path) = (shift, shift);
    my (%do, @specials);
    while(@_)   # protect order of specials
    {    my ($el, $do) = (shift, shift);
         if(ref $do eq 'BLOCK' || ref $do eq 'ANY')
              { push @specials, $do }
         else { $do{$el} = $do }
    }
 
    if(!@specials && keys %do==1)
    {   my ($take, $do) = %do;
        return bless sub {
            my ($doc, $values) = @_;
            defined $values && defined $values->{$take}
              ? $do->($doc, delete $values->{$take}) : ();
        }, 'BLOCK';
    }

    bless sub {
        my ($doc, $values) = @_;
        defined $values or return ();
        foreach my $take (keys %do)
        {
#warn "TAKE($take) = ", (defined $values->{$take} ? 'defined' : "undef");
            return $do{$take}->($doc, delete $values->{$take})
                if defined $values->{$take};
        }

#warn "TRY SPECIALS";
        my $starter = keys %$values;
        foreach (@specials)
        {   my @d = try { $_->($doc, $values) };
            if($@->wasFatal(class => 'misfit'))
            {   # misfit error is ok, if nothing consumed
                my $err = $@;
                trace "misfit $path ".$err->wasFatal->message;
                $err->reportAll if $starter != keys %$values;
                next;
            }
            elsif(defined $@) {$@->reportAll}

            return @d;
        }

#warn "BLURK!";
        # blurk... any element with minOccurs=0 or default?
        foreach (values %do)
        {   my @d = try { $_->($doc, undef) };
            return @d if !$@ && @d;
        }
        foreach (@specials)
        {   my @d = try { $_->($doc, undef) };
            if($@->wasFatal(class => 'misfit'))
            {   $@->reportAll if $starter != keys %$values;
                next;
            }
            elsif(defined $@) {$@->reportAll}
            return @d;
        }

        ();
    }, 'BLOCK';
}

sub makeAll($@)
{   my ($self, $path, @pairs) = @_;

    if(@pairs==2 && !ref $pairs[1])
    {   my ($take, $do) = @pairs;
        return bless sub {
            my ($doc, $values) = @_;
           $do->($doc, delete $values->{$take});
        }, 'BLOCK';
    }

    return bless sub {
        my ($doc, $values) = @_;

        my @res;
        my @do = @pairs;
        while(@do)
        {   my ($take, $do) = (shift @do, shift @do);
            push @res
               , ref $do eq 'BLOCK' || ref $do eq 'ANY'
               ? $do->($doc, $values)
               : $do->($doc, delete $values->{$take});
        }
        @res;
    }, 'BLOCK';
}
 
#
## Element
#

# see comment BlockHandler: undef means zero but success
sub makeElementHandler
{   my ($self, $path, $label, $min,$max, $required, $optional) = @_;
    $max eq "0" and return sub {};

    if($min==0 && $max eq 'unbounded')
    {   return
        sub { my ($doc, $values) = @_;
              my @values = ref $values eq 'ARRAY' ? @$values
                         : defined $values ? $values : ();
              @values ? map {$optional->($doc,$_)} @values : (undef);
            };
    }

    if($max eq 'unbounded')
    {   return
        sub { my ($doc, $values) = @_;
              my @values = ref $values eq 'ARRAY' ? @$values
                         : defined $values ? $values : ();
              my @d = ( (map { $required->($doc, shift @values) } 1..$min)
                      , (map { $optional->($doc, $_) } @values) );
              @d ? @d : (undef);
            };
    }

    return sub { my @d = $optional->(@_); @d ? @d : undef }
        if $min==0 && $max==1;

    return $required
        if $min==1 && $max==1;

    sub {
        my ($doc, $values) = @_;
        my @values
          = ref $values eq 'ARRAY' ? @$values : defined $values ? $values : ();

        @values <= $max
            or error "too many elements for `{tag}', max {max} found {nr} at {path}"
                 , tag => $label, max => $max, nr => (scalar @values)
                 , path => $path;

        my @d = map { $required->($doc, shift @values) } 1..$min;
        push @d, $optional->($doc, shift @values)
            while @values && @d < $max;

        @d ? @d : (undef);
    };
}

# To reflect the difference between a block which did not "succeed hence
# produced nothing", and "did succeed by producing nothing" (minOccurs=0)
# the later is represented by an undef value.
sub makeBlockHandler
{   my ($self, $path, $label, $min, $max, $process, $kind, $multi) = @_;

    if($min==0 && $max eq 'unbounded')
    {   my $code = sub {
            my $doc    = shift;
            my $values = $_[0] ? delete shift->{$multi} : undef;
              ref $values eq 'ARRAY' ? (map {$process->($doc, {%$_})} @$values)
            : defined $values        ? $process->($doc, $values)
            :                          (undef);
        };
        return ($multi, bless($code, 'BLOCK'));
    }

    if($max eq 'unbounded')
    {   my $code = sub {
            my $doc    = shift;
            my $values = $_[0] ? delete shift->{$multi} : undef;
            my @values = ref $values eq 'ARRAY' ? @$values
                       : defined $values ? $values : ();

            @values >= $min
                or error __x"too few blocks for `{tag}' specified, got {found} need {min} at {path}"
                     , tag => $multi, found => scalar @values
                     , min => $min, path => $path, _class => 'misfit';

            map {$process->($doc, {%$_}) } @values;
        };
        return ($multi, bless($code, 'BLOCK'));
    }

    if($min==0 && $max==1)
    {   my $code = sub {
            my ($doc, $values) = @_;
            my @values = ref $values eq 'ARRAY' ? @$values
                       : defined $values ? $values : ();
            @values <= 1
                or error __x"only one block value for `{tag}', not {count} at {path}"
                     , tag => $multi, count => scalar @values
                     , path => $path, _class => 'misfit';

#           @values ? $process->($doc, $values[0]) : undef;
            @values or return undef;

            my $starter = keys %$values;
            my @d = try { $process->($doc, $values[0]) };
            $@->wasFatal(class => 'misfit') && $starter==keys %$values
                or $@->reportAll;
            @d;
        };
        return ($label, bless($code, 'BLOCK'));
    }

    if($min==1 && $max==1)
    {   my $code = sub {
            my @d = $process->(@_);
            @d or error __x"no match for required block `{tag}' at {path}"
              , tag => $multi, path => $path, _class => 'misfit';
            @d;
        };
        return ($label, bless($code, 'BLOCK'));
    }

    my $opt  = $max - $min;
    my $code = sub {
        my $doc    = shift;
        my $values = delete shift->{$multi};
        my @values = ref $values eq 'ARRAY' ? @$values
                   : defined $values ? $values : ();

        @values >= $min && @values <= $max
            or error __x"found {found} blocks for `{tag}', must be between {min} and {max} inclusive at {path}"
                 , tag => $multi, min => $min, max => $max, path => $path
                 , found => scalar @values, _class => 'misfit';

        map { $process->($doc, {%$_}) } @values;
    };

    ($multi, bless($code, 'BLOCK'));
}

sub makeRequired
{   my ($self, $path, $label, $do) = @_;
    my $req = sub {
        my @nodes = $do->(@_);
        return @nodes if @nodes;

        error __x"required data for block (starts with `{tag}') missing at {path}"
          , tag => $label, path => $path, _class => 'misfit'
            if ref $do eq 'BLOCK';

        error __x"required value for element `{tag}' missing at {path}"
          , tag => $label, path => $path, _class => 'misfit';
    };
    bless $req, 'BLOCK' if ref $do eq 'BLOCK';
    $req;
}

sub makeElement
{   my ($self, $path, $ns, $childname, $do) = @_;
    sub { defined $_[1] ? $do->(@_) : () };
}

sub makeElementFixed
{   my ($self, $path, $ns, $childname, $do, $fixed) = @_;
    $fixed = $fixed->value if ref $fixed;

    sub {
        my ($doc, $value) = @_;
        my $ret = defined $value ? $do->($doc, $value) : return;
        return $ret
            if defined $ret && $ret->textContent eq $fixed;

        defined $ret
            or error __x"required element `{name}' with fixed value `{fixed}' missing at {path}"
                 , name => $childname, fixed => $fixed, path => $path,
                 , _class => 'misfit';

        error __x"element `{name}' has value fixed to `{fixed}', got `{value}' at {path}"
           , name => $childname, fixed => $fixed
           , value => $ret->textContent, path => $path, _class => 'misfit';
    };
}

sub makeElementDefault
{   my ($self, $path, $ns, $childname, $do, $default) = @_;
    my $mode = $self->{default_values};

    $mode eq 'IGNORE'
        and return sub { defined $_[1] ? $do->(@_) : () };

    $mode eq 'EXTEND'
        and return sub { $do->($_[0], (defined $_[1] ? $_[1] : $default)) };

    $mode eq 'MINIMAL'
        and return sub { defined $_[1] && $_[1] ne $default ? $do->(@_) : () };

    error __x"illegal default_values mode `{mode}'", mode => $mode;
}

sub makeElementAbstract
{   my ($self, $path, $ns, $childname, $do, $default) = @_;
    sub { defined $_[1] or return ();
          error __x"attempt to instantiate abstract element `{name}' at {where}"
            , name => $childname, where => $path;
        };
}

#
# complexType/ComplexContent
#

sub nil($)
{   my ($self, $path) = @_;
    $self->makeTagQualified($path, undef, 'nil', SCHEMA2001i);
}

sub makeComplexElement
{   my ($self, $path, $tag, $elems, $attrs, $any_attr,undef, $is_nillable) = @_;
    my @elems   = odd_elements @$elems;
    my @attrs   = @$attrs;
    my $tags    = join ', ', grep defined
      , even_elements(@$elems), even_elements(@attrs);
    my @anya    = @$any_attr;
    my $iut     = $self->{ignore_unused_tags};
    my $nilattr = $is_nillable ? $self->nil($path) : undef;

    return
    sub
    {   my ($doc, $data) = @_;
        $data = { _ => 'NIL' } if $data eq 'NIL';

        return $doc->importNode($data)
            if UNIVERSAL::isa($data, 'XML::LibXML::Element');

        unless(UNIVERSAL::isa($data, 'HASH'))
        {   defined $data
                or error __x"complex `{tag}' requires data at {path}"
                      , tag => $tag, path => $path, _class => 'misfit';

            error __x"complex `{tag}' requires a HASH of input data, not `{got}' at {path}"
               , tag => $tag, got => (ref $data || $data), path => $path;
        }

        my $copy   = { %$data };  # do not destroy callers hash

        my @childs = ($is_nillable && (delete $copy->{_} || '') eq 'NIL')
          ? $doc->createAttribute($nilattr => 'true')
          : map($_->($doc, $copy), @elems);

        for(my $i=0; $i<@attrs; $i+=2)
        {   push @childs, $attrs[$i+1]->($doc, delete $copy->{$attrs[$i]});
        }

        push @childs, $_->($doc, $copy)
            for @anya;

        if(%$copy)
        {   my @not_used
              = defined $iut ? (grep $_ !~ $iut, keys %$copy) : keys %$copy;

            if(@not_used)
            {   trace "available tags are: $tags";
                mistake __xn "tag `{tags}' not used at {path}"
                 , "unused tags {tags} at {path}"
                 , scalar @not_used, tags => [sort @not_used], path => $path;
            }
        }

        my $node  = $doc->createElement($tag);

        foreach my $child (@childs)
        {   defined $child or next;
            if(ref $child)
            {   next if UNIVERSAL::isa($child, 'XML::LibXML::Text')
                     && $child->data eq '';
            }
            else
            {   length $child or next;
                $child = XML::LibXML::Text->new($child);
            }
            $node->addChild($child);
        }

        $node;
    };
}

#
# complexType/simpleContent
#

sub makeTaggedElement
{   my ($self, $path, $tag, $st, $attrs, $attrs_any,undef, $is_nillable) = @_;
    my @attrs   = @$attrs;
    my @anya    = @$attrs_any;
    my $nilattr = $is_nillable ? $self->nil($path) : undef;

    return sub {
        my ($doc, $data) = @_;
        return $doc->importNode($data)
            if UNIVERSAL::isa($data, 'XML::LibXML::Element');

        my $copy    = UNIVERSAL::isa($data,'HASH') ? {%$data} : {_ => $data};
        my $content = delete $copy->{_};

        my ($node, @childs);
        if(UNIVERSAL::isa($content, 'XML::LibXML::Node'))
        {   $node = $doc->importNode($content);
        }
        elsif($is_nillable && $content eq 'NIL')
        {   push @childs, $doc->createAttribute($nilattr => 'true');
        }
        elsif(defined $content)
        {   push @childs, $st->($doc, $content);
        }

        for(my $i=0; $i<@attrs; $i+=2)
        {   push @childs, $attrs[$i+1]->($doc, delete $copy->{$attrs[$i]});
        }

        push @childs, $_->($doc, $copy)
            for @anya;

        if(my @not_used = sort keys %$copy)
        {   error __xn "tag `{tags}' not processed at {path}"
                     , "unprocessed tags {tags} at {path}"
                     , scalar @not_used, tags => \@not_used, path => $path;
        }

        $node or @childs or return ();
        $node ||= $doc->createElement($tag);
        $node->addChild
          ( UNIVERSAL::isa($_, 'XML::LibXML::Node') ? $_
          : $doc->createTextNode(defined $_ ? $_ : ''))
             for @childs;
        $node;
    };
}

#
# complexType mixed or complexContent mixed
#

sub makeMixedElement
{   my ($self, $path, $tag, $elems, $attrs, $attrs_any,undef, $is_nillable) =@_;
    my @attrs   = @$attrs;
    my @anya    = @$attrs_any;
    my $nilattr = $is_nillable ? $self->nil($path) : undef;
    (my $locname = $tag) =~ s/.*\://;

    my $mixed = $self->{mixed_elements};
    if($mixed eq 'ATTRIBUTES') { ; }
    elsif($mixed eq 'STRUCTURAL')
    {   # mixed_element eq STRUCTURAL is handled earlier
        panic "mixed structural handled as normal element";
    }
    else { error __x"unknown mixed_elements value `{value}'", value => $mixed }

    if(!@attrs && !@anya)
    {   return
        sub { my ($doc, $data) = @_;
              my $node = ref $data eq 'HASH' ? $data->{_} : $data;
              return $doc->importNode($node)
                  if UNIVERSAL::isa($node, 'XML::LibXML::Element');
              error __x"mixed `{tag}' requires XML::LibXML::Node, not `{found}' at {path}"
                 , tag => $tag, found => $data, path => $path;
            };
    }

    my $iut     = $self->{ignore_unused_tags};
    sub { my ($doc, $data) = @_;
          defined $data or return;

          return $doc->importNode($data)
              if UNIVERSAL::isa($data, 'XML::LibXML::Element');

          my $copy    = UNIVERSAL::isa($data, 'HASH') ? {%$data} : {_ => $data};
          my $content = delete $copy->{_};
          defined $content or return;

          #XXX there are no regression test for these options
          my $node;
          if(blessed $content && $content->isa('XML::LibXML::Node'))
          {   $node    = $doc->importNode($content);
          }
          elsif($is_nillable && $content eq 'NIL')
          {   # nillable element
              $node    = $doc->createElement($tag);
              $node->setAttribute($nilattr => 'true');
          }
          elsif($content =~ /\<.*?\>|\&\w+\;/)
          {   # XXX I do not know a way to fill text nodes without getting
              # entity encoding on them.  Apparently, libxml2 has a
              # xmlStringTextNoenc, which is not provided in XML::LibXML.
              # Now, we need the expensive roundtrip, via the parser.

              my $frag = XML::LibXML->new
                ->parse_balanced_chunk(encode utf8 => $content);

              $node = $frag->firstChild;
              if($node->localName ne $locname)
              {   # <nodes>  -->   <$locname>$nodes</$locname>
                  my $c = $node;
                  $node = $doc->createElement($tag);
                  $node->appendChild($frag);
              }
          }
          else
          {   # Plain text
              $node    = $doc->createElement($tag);
              $node->appendText($content);
          }

          my @childs;
          for(my $i=0; $i<@attrs; $i+=2)
          {   push @childs, $attrs[$i+1]->($doc, delete $copy->{$attrs[$i]});
          }

          push @childs, $_->($doc, $copy)
              for @anya;

          if(%$copy)
          {   my @not_used
                = defined $iut ? (grep $_ !~ $iut, keys %$copy) : keys %$copy;

              if(my @not_used = sort keys %$copy)
              {   error __xn "tag `{tags}' not processed at {path}"
                    , "unprocessed tags {tags} at {path}", scalar @not_used
                    , tags => [sort @not_used], path => $path;
              }
          }

          @childs or return $node;
          $node->addChild
            ( ref $_ && $_->isa('XML::LibXML::Node') ? $_
            : $doc->createTextNode(defined $_ ? $_ : ''))
               for @childs;
          $node;
       };
}

#
# simpleType
#

sub makeSimpleElement
{   my ($self, $path, $tag, $st, undef, undef, undef, $is_nillable) = @_;
    my $nilattr = $is_nillable ? $self->nil($path) : undef;

    sub {
        my ($doc, $data) = @_;
        return $doc->importNode($data)
            if UNIVERSAL::isa($data, 'XML::LibXML::Element');
        $data = $data->{_}
            if ref $data eq 'HASH';

        my $value = ($is_nillable && $data eq 'NIL')
          ? $doc->createAttribute($nilattr => 'true')
          : $st->($doc, $data);

        defined $value
            or return ();

        my $node  = $doc->createElement($tag);
        error __x"expected single value for {tag}, but got {type}"
          , tag => $tag, type => ref($value)
            if ref $value eq 'ARRAY' || ref $value eq 'HASH';

        $node->addChild
          ( UNIVERSAL::isa($value, 'XML::LibXML::Node') ? $value
          : $doc->createTextNode(defined $value ? $value : ''));
        $node;
    };
}

sub makeBuiltin
{   my ($self, $path, $node, $type, $def, $check_values) = @_;
    my $check  = $check_values ? $def->{check} : undef;
    my $err    = $path eq $type
      ? N__"illegal value `{value}' for type {type}"
      : N__"illegal value `{value}' for type {type} at {path}";

    my $format = $def->{format};
    my $trans  = $self->{prefixes};

    $check
    ? ( defined $format
      ? sub { defined $_[1] or return undef;
              my $value = $format->($_[1], $trans, $path);
              return $value if defined $value && $check->($value);
              error __x$err, value => $value, type => $type, path => $path;
            }
      : sub { return $_[1] if !defined $_[1] || $check->($_[1]);
              error __x$err, value => $_[1], type => $type, path => $path;
            }
      )
    : ( defined $format
      ? sub { defined $_[1] ? $format->($_[1], $trans, $path) : undef }
      : sub { $_[1] }
      );
}

# simpleType

sub makeList
{   my ($self, $path, $st) = @_;
    sub { my ($doc, $v) = @_;
        defined $v or return undef;
        join ' ', grep defined, map {$st->($doc, $_)}
            ref $v eq 'ARRAY' ? @$v : $v;
    };
}

sub makeFacetsList
{   my ($self, $path, $st, $info, $early, $late) = @_;
    my @e = grep defined, @$early;
    my @l = grep defined, @$late;
    sub { my ($doc, $v) = @_;
        defined $v or return undef;
        $_->($v) for @l;
        my $list = join ' ', map {$st->($doc, $_)} ref $v eq 'ARRAY' ? @$v : $v;
        defined $list && length $list or return;
        do { $list = $_->($list) } for @e;
        $list;
    }
}

sub makeFacets
{   my ($self, $path, $st, $info, @do) = @_;
    @do or return $st;
    sub { defined $_[1] or return undef;
          my $v = $st->(@_);
          for(reverse @do)
          { defined $v or return (); $v = $_->($v) }
          $v;
        };
}

sub makeUnion
{   my ($self, $path, @types) = @_;
    sub { my ($doc, $value) = @_;
          defined $value or return undef;
          for(@types) {my $v = try { $_->($doc, $value) }; $@ or return $v }

          substr $value, 20, -5, '...' if length($value) > 50;
          error __x"no match for `{text}' in union at {path}"
             , text => $value, path => $path;
        };
}

sub makeSubstgroup
{   my ($self, $path, $type, %done) = @_;

    keys %done or return bless sub { () }, 'BLOCK';
    my %do = map { @$_ } values %done;

    bless
    sub { my ($doc, $values) = @_;
#warn "SUBST($type) AVAILABLE ARE ", join ', ', keys %do;
          foreach my $take (keys %do)
          {   my $subst = delete $values->{$take};
              defined $subst or next;

              return $do{$take}->($doc, $subst);
          }
          ();
        }, 'BLOCK';
}

# Attributes

sub makeAttributeRequired
{   my ($self, $path, $ns, $tag, $label, $do) = @_;

    sub { my $value = $do->(@_);
          return $_[0]->createAttribute($tag, $value)
              if defined $value;

          error __x"attribute `{tag}' is required at {path}"
             , tag => $tag, path => $path;
        };
}

sub makeAttributeProhibited
{   my ($self, $path, $ns, $tag, $label, $do) = @_;

    sub { my $value = $do->(@_);
          defined $value or return ();

          error __x"attribute `{tag}' is prohibited at {path}"
             , tag => $tag, path => $path;
        };
}

sub makeAttribute
{   my ($self, $path, $ns, $tag, $label, $do) = @_;
    sub { my $value = $do->(@_);
          defined $value ? $_[0]->createAttribute($tag, $value) : ();
        };
}

sub makeAttributeDefault
{   my ($self, $path, $ns, $tag, $label, $do, $default_node) = @_;

    my $mode = $self->{default_values};
    $mode eq 'IGNORE'
       and return sub
         { my $value = $do->(@_);
           defined $value ? $_[0]->createAttribute($tag, $value) : ();
         };

    my $default = $default_node->value;
    $mode eq 'EXTEND'
        and return sub
          { my $value = $do->(@_);
            defined $value or $value = $default;
            $_[0]->createAttribute($tag, $value);
          };

    $mode eq 'MINIMAL'
        and return sub
          { my $value = $do->(@_);
            return () if defined $value && $value eq $default;
            $_[0]->createAttribute($tag, $value);
          };

    error __x"illegal default_values mode `{mode}'", mode => $mode;
}

sub makeAttributeFixed
{   my ($self, $path, $ns, $tag, $label, $do, $fixed) = @_;
    $fixed   = $fixed->value if ref $fixed;

    sub { my ($doc, $value) = @_;
          defined $value or return ();

          $value eq $fixed
              or error __x"value of attribute `{tag}' is fixed to `{fixed}', not `{got}' at {path}"
                   , tag => $tag, got => $value, fixed => $fixed, path => $path;

          $doc->createAttribute($tag, $fixed);
        };
}

# any

sub _split_any_list($$$)
{   my ($path, $type, $v) = @_;
    my @nodes = ref $v eq 'ARRAY' ? @$v : defined $v ? $v : return ([], []);
    my (@attrs, @elems);

    foreach my $node (@nodes)
    {   UNIVERSAL::isa($node, 'XML::LibXML::Node')
            or error __x"elements for 'any' are XML::LibXML nodes, not {string} at {path}"
                  , string => $node, path => $path;

        if($node->isa('XML::LibXML::Attr'))
        {   push @attrs, $node;
            next;
        }

        if($node->isa('XML::LibXML::Element'))
        {   push @elems, $node;
            next;
        }

        error __x"an XML::LibXML::Element or ::Attr is expected as 'any' or 'anyAttribute value with {type}, but a {kind} was found at {path}"
           , type => $type, kind => ref $node, path => $path;
    }

    return (\@attrs, \@elems);
}

sub makeAnyAttribute
{   my ($self, $path, $handler, $yes, $no, $process) = @_;
    my %yes   = map +($_ => 1), @{$yes || []};
    my %no    = map +($_ => 1), @{$no  || []};
    my $prefs = $self->{prefixes};

    weaken $self;

    bless
    sub { my ($doc, $values) = @_;

          my @res;
          foreach my $label (sort keys %$values)
          {   my ($type, $ns, $local);
              if(substr($label, 0, 1) eq '{')
              {   ($ns, $local) = unpack_type $label;
                  $type         = $label;
              }
              elsif(index($label, ':') >= 0)
              {   (my $prefix, $local) = split ':', $label, 2;
                  my $match = first {$_->{prefix} eq $prefix} values %$prefs;
                  my $ns    = $match ? $match->{uri} : undef;
                  $type     = pack_type $ns, $local;
              }
              else {next}  # not fully qualified, not an 'any'

              $yes{$ns} or next if keys %yes;
              $no{$ns} and next if keys %no;

              my $value = delete $values->{$label} or next;
              my ($attrs, $elems) = _split_any_list $path, $type, $value;

              $values->{$type} = $elems if @$elems;
              @$attrs or next;

              foreach my $node (@$attrs)
              {   my $nodetype = type_of_node $node;
                  next if $nodetype eq $type;

                  error __x"provided 'anyAttribute' node has type {type}, but labeled with {other} at {path}"
                     , type => $nodetype, other => $type, path => $path
              }

              push @res, @$attrs;
          }
          @res;
        }, 'ANY';
}

sub makeAnyElement
{   my ($self, $path, $handler, $yes, $no, $process, $min, $max) = @_;
    my %yes   = map +($_ => 1), @{$yes || []};
    my %no    = map +($_ => 1), @{$no  || []};
    my $prefs = $self->{prefixes};

    $handler ||= 'SKIP_ALL';
    weaken $self;

    bless
    sub { my ($doc, $values) = @_;
          my @res;

          foreach my $label (sort keys %$values)
          {   my ($type, $ns, $local);
              if(substr($label, 0, 1) eq '{')
              {   ($ns, $local) = unpack_type $label;
                  $type         = $label;
              }
              elsif(index($label, ':') >= 0)
              {   (my $prefix, $local) = split ':', $label, 2;
                  my $match = first {$_->{prefix} eq $prefix} values %$prefs;
                  $ns    = $match ? $match->{uri} : undef;
                  $type  = pack_type $ns, $local;
              }
              else {next}  # not fully qualified, not an 'any'

              $yes{$ns} or next if keys %yes;
              $no{$ns} and next if keys %no;

              my $value = delete $values->{$label} or next;
              my ($attrs, $elems) = _split_any_list $path, $type, $value;

              $values->{$type} = $attrs if @$attrs;
              @$elems or next;

              foreach my $node (@$elems)
              {   my $nodens = $node->namespaceURI;
                  defined $nodens or next; # see README.todo work-around

                  my $nodetype = type_of_node $node;
                  next if $nodetype eq $type;

                  error __x"provided 'any' element node has type {type}, but labeled with {other} at {path}"
                     , type => $nodetype, other => $type, path => $path
              }

              push @res, @$elems;
              $max eq 'unbounded' || @res <= $max
                  or error __x"too many 'any' elements after consuming {count} nodes of {type}, max {max} at {path}"
                       , count => scalar @$elems, type => $type
                       , max => $max, path => $path;
          }

          @res >= $min
              or error __x"too few 'any' elements, got {count} for minimum {min} at {path}"
                   , count => scalar @res, min => $min, path => $path;

          @res ? @res : undef;   # empty, then "0 but true"
        }, 'ANY';
}

# xsi:type handling

sub makeXsiTypeSwitch($$$$)
{   my ($self, $where, $elem, $default_type, $types) = @_;
    my $xsi = $self->_registerNSprefix(xsi => SCHEMA2001i, 1) . ':type';
    my %types;
    foreach my $type (sort keys %$types)
    {   my ($ns, $local) = unpack_type $type;
        my $tag = $self->makeTagQualified($where, undef, $local, $ns);

        # register code under both prefixed and full type name
        $types{$self->prefixed($type)} = $types{$type} = [$tag,$types->{$type}];
    }

    sub {
        my ($doc, $values) = @_;
        ref $values eq 'HASH' && $values->{XSI_TYPE}
            or return $types{$default_type}[1]->(@_);

        my %v    = %$values;
        my $type = delete $v{XSI_TYPE};
        my $def  = $types{$type}
            or error __x"specified xsi:type list for `{default}' does not contain `{got}'"
                 , default => $default_type, got => $type;

        my ($t, $code) = @$def;
        my $node = $code->($doc, \%v)
            or return;
        $node->setAttribute($xsi, $t);
        $node;
    };
}

sub makeHook($$$$$$$)
{   my ($self, $path, $r, $tag, $before, $replace, $after, $fulltype) = @_;
    return $r unless $before || $replace || $after;

    my $do_replace;
    if($replace)
    {   return sub {()} if grep $_ eq 'SKIP', @$replace;

        # Input for replace is Perl, output is XML... so we cannot stack them
        error __x"writer only supports one replace hook (for {type})"
          , type => $fulltype
            if @$replace > 1;

        $do_replace = $self->_decodeReplace($path, $replace->[0]);
    }

    my @do_before = $before ? map $self->_decodeBefore($path,$_), @$before :();
    my @do_after  = $after  ? map $self->_decodeAfter($path,$_),  @$after  :();

    sub
    {  my ($doc, $val) = @_;
       defined $val or return;
       foreach (@do_before)
       {   $val = $_->($doc, $val, $path, $fulltype);
           defined $val or return ();
       }

       my $xml = $do_replace
               ? $do_replace->($doc, $val, $path, $tag, $r, $fulltype)
               : $r->($doc, $val);
       defined $xml or return ();

       foreach (@do_after)
       {   $xml = $_->($doc, $xml, $path, $val, $fulltype);
           defined $xml or return ();
       }

       $xml;
    };
}

sub _decodeBefore($$)
{   my ($self, $path, $call) = @_;
    return $call if ref $call eq 'CODE';

    # $code->($doc, $values, $path)
      $call eq 'PRINT_PATH' ? sub { print "$_[2]\n"; $_[1] }
    : error __x"labeled before hook `{name}' undefined for WRITER", name=>$call;
}

sub _decodeReplace($$)
{   my ($self, $path, $call) = @_;
    return $call if ref $call eq 'CODE';

    # SKIP already handled
    # $replace->($doc, $val, $path, $tag, $replaced)
    error __x"labeled replace hook `{name}' undefined for WRITER", name=>$call;
}

sub _decodeAfter($$)
{   my ($self, $path, $call) = @_;
    return $call if ref $call eq 'CODE';

      $call eq 'PRINT_PATH' ? sub { print "$_[2]\n"; $_[1] }
    : error __x"labeled after hook `{name}' undefined for WRITER", name=>$call;
}

sub makeBlocked($$$)
{   my ($self, $where, $class, $type) = @_;
    my $err_type = $self->prefixed($type);

    # errors are produced in class=misfit to allow other choices to succeed.
      $class eq 'anyType'
    ? { st => sub { error __x"use of `{type}' blocked at {where}"
              , type => $err_type, where => $where, _class => 'misfit';
          }}
    : $class eq 'simpleType'
    ? { st => sub { error __x"use of {class} `{type}' blocked at {where}"
              , class => $class, type => $err_type, where => $where
              , _class => 'misfit';
          }}
    : $class eq 'complexType'
    ? { elems => [] }
    : $class eq 'ref'
    ? { st => sub { error __x"use of referenced `{type}' blocked at {where}"
              , type => $err_type, where => $where, _class => 'misfit';
          }}
    : panic "blocking of $class for $type not implemented";
}

sub addTypeAttribute($$)
{   my ($self, $type, $do) = @_;
    my $xsi   = $self->_registerNSprefix(xsi => SCHEMA2001i, 1) . ':type';
    my $xsd   = $self->_registerNSprefix(xsd => SCHEMA2001, 1);
    my $typed = $self->prefixed($type);

    sub {
        my $r = $do->(@_);
        $type && $r && UNIVERSAL::isa($r, 'XML::LibXML::Element') or return $r;
        return $r if $r->getAttributeNS(SCHEMA2001i, 'type');
        $r->setAttribute($xsi, $typed);
        $r;
    };
}

#------------
=chapter DETAILS

=section Processing Wildcards

Complex elements can define C<any> (element) and C<anyAttribute> components,
with unpredictable content.  In this case, you are quite on your own in
processing those constructs.  The use of both schema components should
be avoided: please specify your data-structures explicit by clean type
extensions.

The procedure for the WRITER is simple: add key-value pairs to your
hash, in which the value is a fully prepared M<XML::LibXML::Attr>
or M<XML::LibXML::Element>.  The keys have the form C<{namespace}type>.
The I<namespace> component is important, because only spec conformant
namespaces will be used. The elements and attributes are added in
random order.

=example specify anyAttribute
 use XML::Compile::Util qw/pack_type/;

 my $attr = $doc->createAttributeNS($somens, $sometype, 42);
 my $h = { a => 12     # normal element or attribute
         , "{$somens}$sometype"        => $attr # anyAttribute
         , pack_type($somens, $mytype) => $attr # nicer
         , "$prefix:$sometype"         => $attr # [1.28]
         };

=section Mixed elements

[0.79] ComplexType and ComplexContent components can be declared with the
C<<mixed="true">> attribute.

XML::Compile does not have a way to express these mixtures of information
and text as Perl data-structures; the only way you can use those to the
full extend, is by juggling with XML::LibXML nodes yourself.

You may provide a M<XML::LibXML::Element>, which is complete, or a
HASH which contains attributes values and an XML node with key '_'.
When '_' contains a string, it will be translated into an XML text
node.

M<XML::Compile::Schema::compile(mixed_elements)> can be set to
=over 4
=item ATTRIBUTES (default)
Add attributes to the provided node.  When you provide a HASH, it is
taken as node content with attributes.  The content has to be stored
with key '_'.  When it is not a HASH, the data is node content.

There are various ways you can specify content.  Upto [1.51], you
could only pass a matching M<XML::LibXML::Element>.  Release [1.51] added
strings to the spectrum.  If the string does not contain encoded entities
or E<lt> and E<gt>, then it is assumed to be a real perl string.  When
the string contains an XML fragment which has the same localname as to be
created, that will be used.  When the XML fragment is not wrapped in the
expected node, this is created for you.

In any case, attributes provided with the content will get added to the
content data.

=item STRUCTURAL
[0.89] behaves as if the attribute is not there: a data-structure can be
used or an XML node.
=back

=section Schema hooks

All writer hooks behave differently.  Be warned that the user values
can be a SCALAR or a HASH, dependent on the type.  You can intervene
on higher data-structure levels, to repair lower levels, if you want
to.

[1.48] The hooks get a long list of parameters.  The C<$fulltype>
indicates the type of object which is being processed, which is
especially useful with the 'extends' selector.

=subsection hooks executed before normal processing

The C<before> hook gives you the opportunity to fix the user
supplied data structure.  The XML generator will complain about
missing, superfluous, and erroneous values which you probably
want to avoid.

The C<before> hook returns new values.  Just must not interfere
with the user provided data.  When C<undef> is returned, the whole
node will be cancelled.

On the moment, the only predefined C<before> hook is C<PRINT_PATH>.

=example before hook on user-provided HASH.
 sub beforeOnComplex($$$$)
 {   my ($doc, $values, $path, $fulltype) = @_;

     my %copy = %$values;
     $copy{extra} = 42;
     delete $copy{superfluous};
     $copy{count} =~ s/\D//g;    # only digits
     \%copy;
 }

=example before hook on simpleType data
 sub beforeOnSimple($$$$)
 {   my ($doc, $value, $path, $fulltype) = @_;
     $value * 100;    # convert euro to euro-cents
 }

=example before hook with object for complexType
 sub beforeOnObject($$$$)
 {   my ($doc, $obj, $path, $fulltype) = @_;

     +{ name     => $obj->name
      , price    => $obj->euro
      , currency => 'EUR'
      };
 }

=subsection hooks replacing the usual XML node generation

Only one C<replace> hook can be defined.  It must return a
M<XML::LibXML::Node> or C<undef>.  The hook must use the
C<XML::LibXML::Document> node (which is provided as first
argument) to create a node.

As parameters, the called replace function will receive the
document, user-provided values, location in the data tree (for
error messages), the tag of the node with prefix attached, and
a reference to the code which would be executed if the replace
hook had not been active.

On the moment, the only predefined C<replace> hook is C<SKIP>.

=example replace hook
 sub replace($$$$$)
 {  my ($doc, $values, $path, $tag, $r, $fulltype) = @_
    my $node = $doc->createElement($tag);
    $node->appendText($values->{text});
    $node;
 }

=subsection hooks executed after the node was created

The C<after> hooks, will each get a chance to modify the
produced XML node, for instance to encapsulate it.  Each time,
the new XML node has to be returned.

On the moment, the only predefined C<after> hook is C<PRINT_PATH>.

=example add an extra sibbling after the usual process
 sub after($$$$)
 {   my ($doc, $node, $path, $values, $fulltype) = @_;
     my $child = $doc->createAttributeNS($myns, earth => 42);
     $node->addChild($child);
     $node;
 }

=subsection fixing bad schemas

When a schema makes a mess out of things, we can fix that with hooks.
Also, when you need things that XML::Compile does not support (yet).

=example creating nodes with text

 {  my $text;

    sub before($$$)
    {   my ($doc, $values, $path) = @_;
        my %copy = %$values;
        $text = delete $copy{text};
        \%copy;
    }

    sub after($$$)
    {   my ($doc, $node, $path) = @_;
        $node->addChild($doc->createTextNode($text));
        $node;
    }

    $schema->addHook
     ( action => 'WRITER'
     , type   => 'mixed'
     , before => \&before
     , after  => \&after
     );
 }

=section Typemaps

In a typemap, a relation between an XML element type and a Perl class (or
object) is made.  Each translator back-end will implement this a little
differently.  This section is about how the writer handles typemaps.

=subsection Typemap to Class

Usually, an XML type will be mapped on a Perl class.  The Perl class
implements the C<toXML> method as serializer.  That method should
either return a data structure which fits that of the specific type,
or an M<XML::LibXML::Element>.

When translating the data-structure to XML, the process may encounter
objects.  Only if these objects appear at locations where a typemap
is defined, they are treated smartly.  When some other data than an
objects is found on a location which has a typemap definition, it will
be used as such; objects are optional.

The object (if present) will be checked to be of the expected class.
It will be a compile-time error when the class does not implement the
C<toXML> method.

 $schema->typemap($sometype => 'My::Perl::Class');

 package My::Perl::Class;
 ...
 sub toXML
 {   my ($self, $xmltype, $doc) = @_;
     ...
     { a => { b => 42 }, c => 'aaa' };
 }

The C<$self> is the object found in the data-structure provided by the
user.  C<$doc> can be used to create your own M<XML::LibXML::Element>.
It is possible to use the same object on locations for different types:
in this case, the toXML method can distiguisk what kind of data to return
based on the C<$xmltype>.

=subsection Typemap to Object

In this case, some helper object arranges the serialization of the
provided object.  This is especially useful when the provided object
does not have the toXML implemented, for instance because it is an
implementation not under your control.  The helper object works like
an interface.

 my $object = My::Perl::Class->new(...);
 $schema->typemap($sometype => $object);

 package My::Perl::Class;
 sub toXML
 {   my ($self, $object, $xmltype, $doc) = @_;
     ...
 }

The toXML will only be called then C<$object> is blessed.  If you wish
to have access to some data-type in any case, then use a simple "before"
hook.

=subsection Typemap to CODE

The light version of an interface object uses CODE references.  The CODE
reference is only called if a blessed value is found in the user provided
data.  It cannot be checked automatically whether it is blessed according
to the expectation.

 $schema->typemap($t1 => \&myhandler);

 sub myhandler
 {   my ($backend, $object, $xmltype, $doc) = @_;
     ...
 }

=subsection Typemap implementation

The typemap for the writer is implemented as a 'before' hook: just before
the writer wants to start.

Of course, it could have been implemented by accepting an object anywhere
in the input data.  However, this would mean that all the (many) internal
parser constructs would need to be extended.  That would slow-down the
writer considerably.

=cut

1;
