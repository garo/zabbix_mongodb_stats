# zabbix_mongodb_stats
Zabbix MongoDB statistics sender

This is a simple script which polls MongoDB instance statistics and sends them to zabbix. It comes along with a Zabbix template.

Usage
=====

Each MongoDB instance needs one statistics sender which sends data for that particular instance to Zabbix. This can be bundled into a Docker container which contains both the MongoDB instance and the Zabbix statistics sender and possibly also my MongoDB Wire Analyzer: https://github.com/garo/node-mongodb-wire-analyzer
