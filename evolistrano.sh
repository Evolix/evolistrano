#!/bin/sh

set -e
set -u

export LC_ALL=C

full_path=`echo $(dirname $(readlink -f $0))`
. $full_path/evolistrano.conf

tmp_dir=`mktemp  -p $tmpdir -d`
dir_export=$tmp_dir/export
time_stamp=`date +%s`

usage() {
        cat <<EOT
Usage: $0 [OPTION] REVNUM

Sans option : Mise en preproduction
-P : Mise en production
EOT
        exit 1
}

read_confirm() {
        read ok
        if [ "$ok" != "y" ]; then
                exit 1
        fi
}

[ $# -lt 1 ] && usage
if [ $1 == "-P" ]; then
        prod=1
        shift
else
        prod=0
fi

[ $# -lt 1 ] && usage
revnum=$1

if [ $prod -eq 1 ]; then
        log_file=$logdir/prod.log
        opname="PRODUCTION"
        destdir="prod"
        sshuser=$deployproduser
        staticdestdir="prod/static"
        confdir=$confproddir
else
        log_file=$logdir/preprod.log
        opname="preprod"
        destdir="preprod"
        sshuser=$deploypreproduser
        staticdestdir="preprod/static"
        confdir=$confpreproddir
fi

# Display infos about deployement
echo
svn info $svnpath -r $revnum

echo -n "Confirmer la mise en $opname de la révision $revnum ? [y/N] "
read_confirm


# Warning if it's not the last revision
last_commited_rev=`svn info $svnpath | grep ^Revision | sed 's/.*: \([0-9]\+\)$/\1/'`
if [ $revnum -ne $last_commited_rev ]; then
        echo -n "Attention, la révision $revnum n'est pas la plus récente. Continuer ? [y/N] "
        read_confirm
fi

tmpfile=`mktemp -p $tmpdir`
cat <<EOT >$tmpfile
Date : `date`
User : $LOGNAME
Revision : $revnum

EOT

# Send email notification
[ $prod -eq 1 ] && [ "$mailnotif" != "" ] && ( cat $tmpfile | mail -s "[Evolistrano] Mise en prod" $mailnotif )

cat $tmpfile >>$log_file
rm $tmpfile

#
umask 022
svn export -r $revnum -q $svnpath $dir_export
echo
echo "SVN export to $dir_export"
echo

#set +e

local_space=`du -sm $dir_export/ | sed 's/^\([0-9]\+\)\t.*$/\1/'`
# Deploy on WWW servers
for remote in $wwwlist; do

    # Be sure to have space for deploying
    remote_space=`ssh -p $sshport -o UserKnownHostsFile=$full_path/known_hosts -i $full_path/$sshkey $sshuser@$remote df -lPm $subdocroot | grep ^/ | tr -s " " | cut -d" " -f4`
    if [ $local_space -ge $remote_space ]; then echo "WARNING... $remote has only $remote_space Mo while you want upload $local_space Mo. Do you want stop ? [y/N]"; read_confirm; fi 

    echo "sending code on $remote"

    if [ "$usehardlinks" = "true" ]; then
        rsync -rlptq --link-dest=../current -e "ssh -p $sshport -o UserKnownHostsFile=$full_path/known_hosts -i $full_path/$sshkey" $dir_export/ --delete $excludelist $sshuser@$remote:$subdocroot/$destdir/$time_stamp
    else
        rsync -rlptq -e "ssh -p $sshport -o UserKnownHostsFile=$full_path/known_hosts -i $full_path/$sshkey" $dir_export/ --delete $excludelist $sshuser@$remote:$subdocroot/$destdir/$time_stamp
    fi

    # Deploy conf files => UNCOMMENT AND ADJUST LINES
    #scp -q -P $sshport -o UserKnownHostsFile=$full_path/known_hosts -i $full_path/$sshkey $full_path/conf-$destdir/foo-global.ini $sshuser@$remote:$subdocroot/$destdir/$time_stamp/config/config/foo/global.ini
    #scp -q -P $sshport -o UserKnownHostsFile=$full_path/known_hosts -i $full_path/$sshkey $full_path/conf-$destdir/foo-database.ini $sshuser@$remote:$subdocroot/$destdir/$time_stamp/config/config/foo/database.ini
    #scp -q -P $sshport -o UserKnownHostsFile=$full_path/known_hosts -i $full_path/$sshkey $full_path/conf-$destdir/bar-config.ini $sshuser@$remote:$subdocroot/$destdir/$time_stamp/config/config/bar/config.ini

    # UNIX rights => ADJUST ALL RIGHTS, PARTICULARLY FOR ADDING WRITE PERMISSIONS
    ssh -p $sshport -o UserKnownHostsFile=$full_path/known_hosts -i $full_path/$sshkey $sshuser@$remote chmod -R g+rX,o+rX $subdocroot/$destdir/$time_stamp
    #ssh -p $sshport -o UserKnownHostsFile=$full_path/known_hosts -i $full_path/$sshkey $sshuser@$remote chmod -R g+w $subdocroot/$destdir/$time_stamp/cache

    # ADD SPECIFIC ACTIONS ON WWW SERVERS

done

local_space=`du -sm $dir_export/$staticfilesdir | sed 's/^\([0-9]\+\)\t.*$/\1/'`
for remote in $staticlist; do

    # Be sure to have space for deploying
    remote_space=`ssh -p $sshport -o UserKnownHostsFile=$full_path/known_hosts -i $full_path/$sshkey $sshuser@$remote df -lPm $subdocroot | grep ^/ | tr -s " " | cut -d" " -f4`
    if [ $local_s -ge $remote_s ]; then echo "WARNING... $remote has only $remote_s Mo while you want upload $local_s Mo : stop deploy now with Ctrl+C"; read enter; fi 

    echo "sending static on $remote"

    rsync -rlptq -e "ssh -o UserKnownHostsFile=$full_path/known_hosts -i $full_path/$sshkey" $dir_export/$staticfilesdir --delete $excludelist $sshuser@$remote:$subdocroot/static
    ssh -o UserKnownHostsFile=$full_path/known_hosts -i $full_path/$sshkey $sshuser@$remote chmod -R g+rX,o+rX $subdocroot/static
done

# Enable new code
last_frontal=`echo -n $wwwlist | sed 's/.* \+\([^ ]\+ *\)$/\1/'`
for remote in `echo -n $wwwlist | sed "s/$last_frontal//"`; do

    if [ $prod -eq 1 ]; then
        echo "stopping Apache on $remote"
	ssh -o UserKnownHostsFile=$full_path/known_hosts -i $full_path/$sshkey $sshuser@$remote sudo /etc/init.d/apache2 stop
    fi

    # Change symlink current to new code
    ssh -o UserKnownHostsFile=$full_path/known_hosts -i $full_path/$sshkey $sshuser@$remote "rm $subdocroot/$destdir/current && cd $subdocroot/$destdir && ln -s $time_stamp current"

    if [ $prod -eq 1 ] && [ "$veryhighcritical" != "true" ]; then
        echo "starting Apache on $remote"
        sleep 3 && ssh -o UserKnownHostsFile=$full_path/known_hosts -i $full_path/$sshkey $sshuser@$remote sudo /etc/init.d/apache2 start
    fi

done

for remote in $last_frontal; do
    ssh -o UserKnownHostsFile=$full_path/known_hosts -i $full_path/$sshkey $sshuser@$remote "rm $subdocroot/$destdir/current && cd $subdocroot/$destdir && ln -s $time_stamp current"
done

if [ "$veryhighcritical" = "true" ]; then
    for remote in `echo -n $wwwlist | sed "s/$last_frontal//"`; do
        echo "starting Apache on $remote"
        ssh -o UserKnownHostsFile=$full_path/known_hosts -i $full_path/$sshkey $sshuser@$remote sudo /etc/init.d/apache2 start
    done
fi

# ADD SPECIFIC ACTIONS (SQL DEPLOYMENT, etc.)

rm -rf $tmp_dir

