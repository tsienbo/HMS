"""Run ONLY against a disposable hms_test_* PostgreSQL database."""
import contextlib
import io
import os
import subprocess
import sys
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'server'))
if not os.environ.get('PGDATABASE', '').startswith('hms_test_'):
    raise RuntimeError('Set PGDATABASE to a disposable hms_test_* database; tests reset its contents')
os.environ['RATE_LIMIT_DISABLED'] = '1'

import psycopg
from db import DB_CONFIG, DB_NAME, query, pool
from init_db import init_database, ensure_schedules
from business_time import today, now
from datetime import timedelta, datetime, timezone
import app as web
import reminder
from validators import hash_password


class AuditRegressions(unittest.TestCase):
    def setUp(self):
        with contextlib.redirect_stdout(io.StringIO()):
            init_database(force=True)
        self.assertEqual(query('SELECT current_database() AS n').rows[0]['n'], DB_NAME)
        self.client = web.app.test_client()
        self.sid = f'SC_DR01_{today() + timedelta(days=1)}_AM'
        login = self.client.post('/api/auth/login', json={'username':'admin','password':'admin123'})
        self.admin = {'Authorization':'Bearer ' + login.json['token']}

    def tearDown(self):
        pool.close_all()

    def patient(self, i):
        pid = f'TP{i}'
        query("""INSERT INTO patients(id,name,id_card,phone_cc,phone,id_type,nationality,sex)
                 VALUES(%s,'Test Patient',%s,'1','2025550100','PASSPORT','US','M')""", [pid,f'TESTPASS{i}'])
        return pid

    def book(self, i, sid=None):
        pid = self.patient(i)
        query("""INSERT INTO appointments(id,appointment_no,seq_no,schedule_id,doctor_id,patient_id,fee,status)
                 SELECT %s,%s,0,s.id,s.doctor_id,%s,d.fee,'booked' FROM schedules s
                 JOIN doctors d ON d.id=s.doctor_id WHERE s.id=%s""",
              [f'TA{i}',f'TESTNO{i}',pid,sid or self.sid])
        return f'TA{i}'

    def wait(self, i):
        pid = self.patient(i)
        query("""INSERT INTO waitlist(id,schedule_id,patient_id,position,status)
                 VALUES(%s,%s,%s,0,'waiting')""", [f'TW{i}',self.sid,pid])
        return f'TW{i}', {'X-Patient-Token': web.issue_patient_token(pid)}

    def two_offers(self):
        query('UPDATE schedules SET max_quota=2 WHERE id=%s',[self.sid])
        a,b = self.book(1),self.book(2)
        w1,h1=self.wait(3); w2,h2=self.wait(4)
        query("UPDATE appointments SET status='cancelled',cancel_reason='admin' WHERE id=ANY(%s)",[[a,b]])
        return w1,h1,w2,h2

    def test_forced_reminder_preserves_business_data(self):
        self.book(1)
        before = query('SELECT id FROM appointments').rows
        result = subprocess.run([sys.executable,str(ROOT/'server/app.py'),'--remind','--force'],
                                env=os.environ.copy(),capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertNotIn('删除并重建所有表',result.stdout)
        self.assertEqual(before,query('SELECT id FROM appointments').rows)
        self.assertEqual(query('SELECT COUNT(*) n FROM patients').rows[0]['n'],1)

    def test_ambiguous_cli_does_not_reset(self):
        self.book(1)
        for args in (['--init','--remind','--force'],['--migrate','--force']):
            r=subprocess.run([sys.executable,str(ROOT/'server/app.py'),*args],capture_output=True)
            self.assertNotEqual(r.returncode,0)
        self.assertEqual(query('SELECT COUNT(*) n FROM appointments').rows[0]['n'],1)

    def test_stop_clinic_is_atomic_against_booking(self):
        self.book(1)
        closed=threading.Event(); release=threading.Event()
        original=web.transaction
        @contextlib.contextmanager
        def observed(*args, **kwargs):
            with original(*args, **kwargs) as run:
                def wrapped(sql, params=None):
                    result=run(sql,params)
                    if 'UPDATE appointments' in sql and "cancel_reason = 'closure'" in sql:
                        closed.set()
                        if not release.wait(5): raise RuntimeError('test release timeout')
                    return result
                yield wrapped
        web.transaction=observed
        try:
            with ThreadPoolExecutor(2) as executor:
                stop=executor.submit(lambda: web.app.test_client().post('/api/schedules/'+self.sid+'/toggle',headers=self.admin))
                self.assertTrue(closed.wait(5))
                payload={'scheduleId':self.sid,'patient':{'name':'Test Patient','idType':'PASSPORT','nationality':'US','idCard':'TESTNEW99','sex':'M','phoneCc':'1','phone':'2025550100'}}
                booking=executor.submit(lambda: web.app.test_client().post('/api/appointments',json=payload))
                release.set()
                self.assertEqual(stop.result(10).status_code,200)
                self.assertEqual(booking.result(10).status_code,409)
            self.assertEqual(query('SELECT booked_count FROM schedules WHERE id=%s',[self.sid]).rows[0]['booked_count'],0)
        finally:
            release.set(); web.transaction=original

    def test_cancel_offer_promotes_next(self):
        query('UPDATE schedules SET max_quota=1 WHERE id=%s',[self.sid])
        a=self.book(1); w1,h1=self.wait(2); w2,_=self.wait(3)
        query("UPDATE appointments SET status='cancelled' WHERE id=%s",[a])
        self.assertEqual(self.client.post('/api/waitlist/'+w1+'/cancel',headers=h1).status_code,200)
        self.assertEqual(query('SELECT status FROM waitlist WHERE id=%s',[w2]).rows[0]['status'],'offered')

    def test_multiple_expired_offers_fill_all_slots(self):
        self.two_offers(); self.wait(5); self.wait(6)
        query("""UPDATE waitlist SET offered_at=NOW()-INTERVAL '3 hours',
                 offer_expires_at=NOW()-INTERVAL '1 hour' WHERE status='offered'""")
        result=reminder.expire_offers()
        self.assertEqual(result,{'expired':2,'reoffered':2})
        self.assertEqual(reminder.expire_offers(),{'expired':0,'reoffered':0})

    def test_concurrent_offers_do_not_share_one_slot(self):
        query('UPDATE schedules SET max_quota=1 WHERE id=%s',[self.sid])
        a=self.book(1); self.wait(2); self.wait(3)
        query("UPDATE appointments SET status='cancelled',cancel_reason='closure' WHERE id=%s",[a])
        with psycopg.connect(**DB_CONFIG,dbname=DB_NAME) as first:
            w1=first.execute('SELECT fn_offer_next_waitlist(%s)',[self.sid]).fetchone()[0]
            started=threading.Event()
            def second():
                started.set()
                with psycopg.connect(**DB_CONFIG,dbname=DB_NAME) as c:
                    return c.execute('SELECT fn_offer_next_waitlist(%s)',[self.sid]).fetchone()[0]
            with ThreadPoolExecutor(1) as executor:
                future=executor.submit(second); self.assertTrue(started.wait(3))
                first.commit()
                self.assertIsNone(future.result(5))
            self.assertIsNotNone(w1)
        self.assertEqual(query("SELECT COUNT(*) n FROM waitlist WHERE status='offered'").rows[0]['n'],1)

    def test_quota_preserves_offers_in_api_and_database(self):
        self.two_offers()
        r=self.client.patch('/api/schedules/'+self.sid+'/quota',headers=self.admin,json={'total':1})
        self.assertEqual(r.status_code,409)
        with self.assertRaises(psycopg.errors.RaiseException):
            query('UPDATE schedules SET max_quota=1 WHERE id=%s',[self.sid])
        self.assertEqual(query('SELECT max_quota FROM schedules WHERE id=%s',[self.sid]).rows[0]['max_quota'],2)

    def test_masked_patient_responses_do_not_expose_document(self):
        pid=self.patient(1)
        query("INSERT INTO users(id,username,password_hash,display_name,role,status) VALUES('UD','desk',%s,'Test desk','desk','active')",[hash_password('test-only')])
        login=self.client.post('/api/auth/login',json={'username':'desk','password':'test-only'})
        h={'Authorization':'Bearer '+login.json['token']}
        for url in ('/api/admin/patients','/api/admin/patients/'+pid):
            r=self.client.get(url,headers=h); self.assertEqual(r.status_code,200)
            row=r.json[0] if isinstance(r.json,list) else r.json
            self.assertTrue(row['masked']); self.assertIsNone(row['docKey'])
            self.assertNotIn('TESTPASS1',str(row))
        self.assertEqual(self.client.get('/api/admin/patients/'+pid+'?reveal=1&reason=test',headers=h).status_code,403)
        r=self.client.get('/api/admin/patients/'+pid+'?reveal=1&reason=test',headers=self.admin)
        self.assertEqual(r.status_code,200); self.assertEqual(r.json['docKey'],'P:US:TESTPASS1')
        self.assertEqual(query('SELECT COUNT(*) n FROM access_log').rows[0]['n'],1)

    def test_business_timezone_matches_database(self):
        self.assertEqual(query('SHOW timezone').rows[0]['TimeZone'],'Asia/Shanghai')
        self.assertEqual(query('SELECT CURRENT_DATE d').rows[0]['d'],today())
        self.assertEqual(now().utcoffset(),timedelta(hours=8))

    def test_worker_rolls_schedules_forward_without_overwriting(self):
        last=today()+timedelta(days=13)
        query('DELETE FROM schedules WHERE work_date=%s',[last])
        query('UPDATE schedules SET max_quota=7 WHERE id=%s',[self.sid])
        reminder.tick(ignore_window=True)
        self.assertEqual(query('SELECT COUNT(*) n FROM schedules WHERE work_date=%s',[last]).rows[0]['n'],52)
        self.assertEqual(query('SELECT max_quota FROM schedules WHERE id=%s',[self.sid]).rows[0]['max_quota'],7)
        self.assertEqual(ensure_schedules(),0)

    def test_dry_run_email_stays_pending(self):
        import mailer
        from unittest.mock import patch
        query("INSERT INTO notification_outbox(channel,template,dedupe_key,recipient,subject,body) VALUES('email','reminder_t1','test-email','nobody@example.invalid','test','test')")
        with patch.object(mailer.CONFIG,'dry_run',True), patch.object(mailer,'send_mail'):
            stats=mailer.flush()
        self.assertEqual(stats['sent'],0)
        self.assertEqual(query("SELECT status FROM notification_outbox WHERE dedupe_key='test-email'").rows[0]['status'],'pending')


if __name__ == '__main__':
    unittest.main(verbosity=2)
