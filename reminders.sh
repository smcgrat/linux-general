#!/bin/bash
# a simple reminder program to send a brief mail to yourself based on the date
# to be used with crontab. format of file to create is yyyymmdd
dir=~/reminders.d 
  # diretory to store the text files for the content of you mails
  # format of file to create is yyyymmdd
today=$(date '+%Y%m%d')
email=your@email.address
for i in $(ls $dir); do
        file=$dir/$i
        if [ "$i" == "$today" ]; then
                cat $file | mail -s "Daily reminder for $today" $email
        fi
done
exit 0
