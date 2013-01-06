=head1 NAME

Mojolicious::Plugin::MailException - Mojolicious plugin to send crash information by email

=head1 SYNOPSIS

    package MyServer;
    use Mojo::Base 'Mojolicious';

    sub startup {
        my ($self) = @_;

        $self->plugin(MailException => {
            from    => 'robot@my.site.com',
            to      => 'mail1@my.domain.com, mail2@his.domain.com',
            sublect => 'My site crashed!',
            headers => {
                'X-MySite' => 'crashed'
            }
        });
    }

=head1 DESCRIPTION

The plugin catches all exceptions, packs them into email and sends
them to email.

There are some plugin options:

=over

=item from

From-address for email (default B<root@localhost>)

=item to

To-address(es) for email (defailt B<webmaster@localhost>)

=item subject

Subject for crash email

=item headers

Hash with headers that have to be added to mail

=item send

Subroutine that can be used to send the mail, example:

    sub startup {
        my ($self) = @_;

        $self->plugin(MailException => {
            send => sub {
                my ($mail, $exception) = @_;

                $mail->send;    # prepared MIME::Lite object
            }
        });
    }

In the function You can send email by yoursef and (or) prepare and
send Your own mail (sms, etc) message using B<$exception> object.
See L<Mojo::Exception>.

=back

=head1 COPYRIGHT AND LICENCE

 Copyright (C) 2012 by Dmitry E. Oboukhov <unera@debian.org>
 Copyright (C) 2012 by Roman V. Nikolaev <rshadow@rambler.ru>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut

package Mojolicious::Plugin::MailException;

our $VERSION = '0.06';
use 5.008008;
use strict;
use warnings;

use Mojo::Base 'Mojolicious::Plugin';
use Data::Dumper;
use Mojo::Exception;
use Carp;
use MIME::Lite;
use MIME::Words ':all';


my $mail_prepare = sub {
    my ($e, $conf, $self, $from, $to, $headers) = @_;
    my $subject = $conf->{subject} || 'Caught exception';
    $subject .= ' (' . $self->req->method . ': ' .
        $self->req->url->to_abs->to_string . ')';
    utf8::encode($subject) if utf8::is_utf8 $subject;
    $subject = encode_mimeword $subject, 'B', 'utf-8';


    my $text = '';
    $text .= "Exception\n";
    $text .= "~~~~~~~~~\n";
    

    $text .= $e->message;
    $text .= "\n";

    my $maxl = eval { length $e->lines_after->[-1][0]; };
    $maxl ||= 5;
    $text .= sprintf "   %*d %s\n", $maxl, @{$_}[0,1] for @{ $e->lines_before };
    $text .= sprintf " * %*d %s\n", $maxl, @{ $e->line }[0,1];
    $text .= sprintf "   %*d %s\n", $maxl, @{$_}[0,1] for @{ $e->lines_after };

    if (@{ $e->frames }) {
        $text .= "\n";
        $text .= "Stack\n";
        $text .= "~~~~~\n";
        for (@{ $e->frames }) {
            $text .= sprintf "    %s: %d\n", @{$_}[1,2];
        }
    }


    eval { utf8::encode($text) if utf8::is_utf8 $text };


    my $mail = MIME::Lite->new(
        From    => $from,
        To      => $to,
        Subject => $subject,
        Type    => 'multipart/mixed',
    );


    $mail->attach(
        Type    => 'text/plain; charset=utf-8',
        Data    => $text
    );
    
    $text  = "Request\n";
    $text .= "~~~~~~~\n";
    my $req = $self->req->to_string;
    $req =~ s/^/    /gm;
    $text .= $req;

    $mail->attach(
        Type        => 'text/plain; charset=utf-8',
        Filename    => 'request.txt',
        Disposition => 'inline',
        Data        => $text
    );

    $mail->add($_ => $headers->{$_}) for keys %$headers;
    return $mail;
};


sub register {
    my ($self, $app, $conf) = @_;

    my $cb = $conf->{send} || sub { $_[0]->send };
    croak "Usage: app->plugin('ExceptionMail'[, send => sub { ... })'"
        unless 'CODE' eq ref $cb;

    my $headers = $conf->{headers} || {};
    my $from = $conf->{from} || 'root@localhost';
    my $to   = $conf->{to} || 'webmaster@localhost';

    croak "headers must be a HASHREF" unless 'HASH' eq ref $headers;

    $app->hook(around_dispatch => sub {
        my ($next, $c) = @_;


        local $SIG{__DIE__} = sub {
            my ($e) = @_;

            unless (ref $e) {
                my @caller = caller;

                $e = Mojo::Exception->new(
                    sprintf '%s at %s line %d', $e, @caller[1,2]);
                my @frames;
                for (my $i = 0; caller($i); $i++) {
                    push @frames => [ caller $i ];
                }
                $e->frames(\@frames);
            }

            my $mail = $mail_prepare->( $e, $conf, $c, $from, $to, $headers );

            eval {
                $cb->($mail, $e);
                1;
            } or warn $@;

            die $e;
        };
        $next->()
    });
}

1;
