#!/usr/bin/env -S python3 -u
# -*- coding: utf-8 -*-

import subprocess,time,argparse,threading,copy,os
from ipaddress import ip_network,ip_address
from dnslib import DNSRecord,RCODE,QTYPE,A,AAAA
from dnslib.server import DNSServer,DNSHandler,BaseResolver,DNSLogger,TCPServer

class FakePool:
    def __init__(self,ip_range):
        net=ip_network(ip_range,strict=False)
        self.version=net.version
        self.first=int(net.network_address) + 1
        self.last=int(net.broadcast_address) - (1 if net.version==4 else 0)
        self.next=self.first
        self.used=set()
        self.free=[]

    def __len__(self):
        return len(self.used)

    def take(self,ip):
        # Reserve exact fake IP loaded from existing mappings
        try:
            value=int(ip_address(ip))
        except ValueError:
            return False
        if value < self.first or value > self.last or value in self.used:
            return False
        self.used.add(value)
        return True

    def pop(self):
        while self.free:
            value=self.free.pop()
            if value not in self.used:
                self.used.add(value)
                return str(ip_address(value))
        while self.next <= self.last:
            value=self.next
            self.next+=1
            if value not in self.used:
                self.used.add(value)
                return str(ip_address(value))
        return None

    def add(self,ip):
        value=int(ip_address(ip))
        self.used.discard(value)
        self.free.append(value)

class ProxyResolver(BaseResolver):
    def __init__(self,address,port,timeout,ip_range,ip_range6,ttl):
        self._env=os.environ.copy()
        self.families={}
        self.load_family(QTYPE.A,"/usr/sbin/iptables","/usr/sbin/iptables-restore",ip_range,True)
        self.load_family(QTYPE.AAAA,"/usr/sbin/ip6tables","/usr/sbin/ip6tables-restore",ip_range6,False)
        self.address=address
        self.port=port
        self.timeout=timeout
        self.ttl=ttl
        # Seconds of inactivity before fake IP is removed
        self.expire=ttl * 2
        self.lock=threading.Lock()
        # Start thread for cleanup fake IPs
        threading.Thread(target=self.cleanup_fake_ips_worker,daemon=True).start()

    def load_family(self,qtype,cmd,restore,ip_range,required):
        # Chain is created by up.sh, its absence means this IP version is disabled
        try:
            result=subprocess.run([cmd,"-w","-t","nat","-S","ANTIZAPRET-MAPPING"],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,check=True,env=self._env)
        except Exception as e:
            if required:
                print(f"Error: {e} ({cmd} chain ANTIZAPRET-MAPPING not found)")
                os._exit(1)
            print(f"Disabled: {QTYPE[qtype]} fake IPs mapping")
            return
        family={"cmd": cmd,"restore": restore,"pool": FakePool(ip_range),"map": {}}
        self.families[qtype]=family
        now=time.time()
        for line in result.stdout.splitlines():
            parts=line.split()
            if len(parts) < 8:
                continue
            fake_ip=parts[3].split("/")[0]
            real_ip=parts[7]
            if not self.mapping_ip(family,real_ip,fake_ip,now):
                print("Restarting: Invalid loaded fake IPs mappings")
                try:
                    subprocess.run([cmd,"-w","-t","nat","-F","ANTIZAPRET-MAPPING"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
                finally:
                    os._exit(1)
        print(f"Loaded: {len(family['map'])} {QTYPE[qtype]} fake IPs")

    def get_fake_ip(self,family,real_ip,now):
        with self.lock:
            entry=family["map"].get(real_ip)
            if entry:
                entry["used"]=now
                return entry["fake_ip"]
            fake_ip=family["pool"].pop()
            if not fake_ip:
                print("Error: No fake IP left")
                return None
            family["map"][real_ip]={"fake_ip": fake_ip,"used": now}
        try:
            subprocess.run([family["cmd"],"-w","-t","nat","-A","ANTIZAPRET-MAPPING","-d",fake_ip,"-j","DNAT","--to-destination",real_ip],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
        except Exception as e:
            print(f"Error: {e} (real_ip={real_ip} fake_ip={fake_ip})")
            with self.lock:
                del family["map"][real_ip]
                family["pool"].add(fake_ip)
            return None
        #print(f"Mapping: {fake_ip} to {real_ip}")
        return fake_ip

    def mapping_ip(self,family,real_ip,fake_ip,now):
        if family["map"].get(real_ip):
            print(f"Error: Real IP {real_ip} is already mapped")
            return False
        if not family["pool"].take(fake_ip):
            print(f"Error: Fake IP {fake_ip} not in fake IP pool")
            return False
        family["map"][real_ip]={"fake_ip": fake_ip,"used": now}
        #print(f"Mapping: {fake_ip} to {real_ip}")
        return True

    def cleanup_fake_ips_worker(self):
        while True:
            time.sleep(self.expire)
            for qtype,family in self.families.items():
                try:
                    self.cleanup_fake_ips(family)
                except Exception as e:
                    print(f"Error: {e}")
                    print(f"Restarting: Cleanup {QTYPE[qtype]} fake IPs failed")
                    try:
                        subprocess.run([family["cmd"],"-w","-t","nat","-F","ANTIZAPRET-MAPPING"],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
                    finally:
                        os._exit(1)

    def cleanup_fake_ips(self,family):
        with self.lock:
            now=time.time()
            cleanup_ips=[]
            rules=["*nat"]
            for real_ip,entry in family["map"].items():
                if now - entry["used"] > self.expire:
                    cleanup_ips.append((real_ip,entry["fake_ip"]))
            for real_ip,fake_ip in cleanup_ips:
                family["pool"].add(fake_ip)
                del family["map"][real_ip]
                rules.append(f"-D ANTIZAPRET-MAPPING -d {fake_ip} -j DNAT --to-destination {real_ip}")
                #print(f"Unmapping: {fake_ip} to {real_ip}")
        if cleanup_ips:
            rules.append("COMMIT")
            subprocess.run([family["restore"],"-w","-n"],input="\n".join(rules).encode(),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True,env=self._env)
            print(f"Cleaned: {len(cleanup_ips)} expired fake IPs")

    def resolve(self,request,handler):
        try:
            if handler.protocol=="udp":
                data=request.send(self.address,self.port,timeout=self.timeout)
            else:
                data=request.send(self.address,self.port,tcp=True,timeout=self.timeout)
            reply=DNSRecord.parse(data)
            qtype=request.q.qtype
            if qtype==QTYPE.A or qtype==QTYPE.AAAA:
                family=self.families.get(qtype)
                if not family:
                    # This IP version is disabled, answer without addresses
                    reply.rr=[record for record in reply.rr if record.rtype!=qtype]
                    return reply
                rdata_class=A if qtype==QTYPE.A else AAAA
                now=time.time()
                for record in reply.rr:
                    record.ttl=self.ttl
                    if record.rtype!=qtype:
                        continue
                    real_ip=str(record.rdata)
                    fake_ip=self.get_fake_ip(family,real_ip,now)
                    if not fake_ip:
                        reply=request.reply()
                        reply.header.rcode=RCODE.SERVFAIL
                        return reply
                    record.rdata=rdata_class(fake_ip)
        except Exception as e:
            print(f"Error: {e} (qname={request.q.qname} qtype={QTYPE[request.q.qtype]} protocol={handler.protocol})")
            reply=request.reply()
            reply.header.rcode=RCODE.SERVFAIL
        return reply

if __name__=="__main__":
    p=argparse.ArgumentParser(description="DNS Proxy")
    p.add_argument("--port",type=int,default=53,
                    metavar="<port>",
                    help="Local proxy port (default:53)")
    p.add_argument("--address",default="127.3.3.3",
                    metavar="<address>",
                    help="Local proxy listen address (default:127.3.3.3)")
    p.add_argument("--upstream",default="127.2.2.2:53",
                    metavar="<dns server:port>",
                    help="Upstream DNS server:port (default:127.2.2.2:53)")
    p.add_argument("--timeout",type=float,default=5,
                    metavar="<timeout>",
                    help="Upstream timeout (default: 5s)")
    p.add_argument("--log",default="truncated,error",
                    help="Log hooks to enable (default: +truncated,+error,-request,-reply,-recv,-send,-data)")
    p.add_argument("--log-prefix",action="store_true",default=False,
                    help="Log prefix (timestamp/handler/resolver) (default: False)")
    p.add_argument("--ip-range",default="198.18.0.0/15",
                    metavar="<ip/mask>",
                    help="Fake IPv4 range (default:198.18.0.0/15)")
    p.add_argument("--ip-range6",default=os.environ.get("FAKE_NET6") or "fd30::/32",
                    metavar="<ip/mask>",
                    help="Fake IPv6 range, taken from FAKE_NET6 in /root/antizapret/setup (default:fd30::/32)")
    p.add_argument("--ttl",type=int,default=1800,
                    metavar="<seconds>",
                    help="TTL in seconds for all records (default: 1800)")
    args=p.parse_args()
    args.dns,_,args.dns_port=args.upstream.partition(":")
    args.dns_port=int(args.dns_port or 53)
    TCPServer.request_queue_size=128
    print("Starting Proxy Resolver...")
    resolver=ProxyResolver(args.dns,args.dns_port,args.timeout,args.ip_range,args.ip_range6,args.ttl)
    logger=DNSLogger(args.log,prefix=args.log_prefix)
    udp_server=DNSServer(resolver,
                           port=args.port,
                           address=args.address,
                           logger=logger,
                           handler=DNSHandler)
    udp_server.start_thread()
    tcp_server=DNSServer(resolver,
                           port=args.port,
                           address=args.address,
                           tcp=True,
                           logger=logger,
                           handler=DNSHandler)
    tcp_server.start_thread()
    print("Started Proxy Resolver: %s:%d -> %s:%d" % (args.address or "*",args.port,args.dns,args.dns_port))
    while udp_server.isAlive():
        time.sleep(1)
