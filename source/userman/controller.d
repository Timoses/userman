/**
	Database abstraction layer

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the General Public License version 3, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module userman.controller;

public import userman.userman;

import vibe.crypto.passwordhash;
import vibe.db.mongo.mongo;
import vibe.http.router;
import vibe.mail.smtp;
import vibe.stream.memory;
import vibe.templ.diet;
import vibe.utils.validation;

import std.algorithm;
import std.array;
import std.exception;
import std.random;
import std.string;


class UserManController {
	private {
		MongoCollection m_users;
		MongoCollection m_groups;
		UserManSettings m_settings;
	}
	
	this(UserManSettings settings)
	{	
		m_settings = settings;

		auto db = connectMongoDB("127.0.0.1").getDatabase(m_settings.databaseName);
		m_users = db["userman.users"];
		m_groups = db["userman.groups"];

		m_users.ensureIndex(["name": 1], IndexFlags.Unique);
		m_users.ensureIndex(["email": 1], IndexFlags.Unique);
	}

	@property UserManSettings settings() { return m_settings; }

	bool isEmailRegistered(string email)
	{
		auto bu = m_users.findOne(["email": email], ["auth": true]);
		return !bu.isNull() && bu.auth.method.get!string.length > 0;
	}

	void validateUser(User usr)
	{
		enforce(usr.name.length > 3, "User names must be at least 3 characters.");
		validateEmail(usr.email);
	}
	
	void addUser(User usr)
	{
		validateUser(usr);
		enforce(m_users.findOne(["name": usr.name]).isNull(), "The user name is already taken.");
		enforce(m_users.findOne(["email": usr.email]).isNull(), "The email address is already in use.");
		usr._id = BsonObjectID.generate();
		m_users.insert(usr);
	}

	BsonObjectID registerUser(string email, string name, string full_name, string password)
	{
		email = email.toLower();
		name = name.toLower();

		validateEmail(email);
		validatePassword(password, password);

		auto need_activation = m_settings.requireAccountValidation;
		auto user = new User;
		user._id = BsonObjectID.generate();
		user.active = !need_activation;
		user.name = name;
		user.fullName = full_name;
		user.auth.method = "password";
		user.auth.passwordHash = generateSimplePasswordHash(password);
		user.email = email;
		if( need_activation )
			user.activationCode = generateActivationCode();
		addUser(user);
		
		if( need_activation )
			resendActivation(email);

		return user._id;
	}

	BsonObjectID inviteUser(string email, string full_name, string message)
	{
		email = email.toLower();

		validateEmail(email);

		auto existing = m_users.findOne(["email": email], ["_id": true]);
		if( !existing.isNull() ) return existing._id.get!BsonObjectID;

		auto user = new User;
		user._id = BsonObjectID.generate();
		user.email = email;
		user.name = email;
		user.fullName = full_name;
		addUser(user);

		if( m_settings.mailSettings ){
			auto msg = new MemoryOutputStream;
			parseDietFileCompat!("userman.mail.invitation.dt",
				User, "user",
				string, "serviceName",
				string, "serviceUrl")(msg,
					Variant(user),
					Variant(m_settings.serviceName),
					Variant(m_settings.serviceUrl));

			auto mail = new Mail;
			mail.headers["From"] = m_settings.serviceName ~ " <" ~ m_settings.serviceEmail ~ ">";
			mail.headers["To"] = email;
			mail.headers["Subject"] = "Invitation";
			mail.headers["Content-Type"] = "text/html";
			mail.bodyText = cast(string)msg.data();
			
			sendMail(m_settings.mailSettings, mail);
		}

		return user._id;
	}

	void activateUser(string email, string activation_code)
	{
		email = email.toLower();

		auto busr = m_users.findOne(["email": email]);
		enforce(!busr.isNull(), "There is no user account for the specified email address.");
		enforce(busr.activationCode.get!string == activation_code, "The activation code provided is not valid.");
		busr.active = true;
		busr.activationCode = "";
		m_users.update(["_id": busr._id], busr);
	}
	
	void resendActivation(string email)
	{
		email = email.toLower();

		auto busr = m_users.findOne(["email": email]);
		enforce(!busr.isNull(), "There is no user account for the specified email address.");
		enforce(!busr.active, "The user account is already active.");
		
		auto user = new User;
		deserializeBson(user, busr);
		
		auto msg = new MemoryOutputStream;
		parseDietFileCompat!("userman.mail.activation.dt",
			User, "user",
			string, "serviceName",
			string, "serviceUrl")(msg,
				Variant(user),
				Variant(m_settings.serviceName),
				Variant(m_settings.serviceUrl));

		auto mail = new Mail;
		mail.headers["From"] = m_settings.serviceName ~ " <" ~ m_settings.serviceEmail ~ ">";
		mail.headers["To"] = email;
		mail.headers["Subject"] = "Account activation";
		mail.headers["Content-Type"] = "text/html";
		mail.bodyText = cast(string)msg.data();
		
		sendMail(m_settings.mailSettings, mail);
	}

	User getUser(BsonObjectID id)
	{
		auto busr = m_users.findOne(["_id": id]);
		enforce(!busr.isNull(), "The specified user id is invalid.");
		auto ret = new User;
		deserializeBson(ret, busr);
		return ret;
	}

	User getUserByName(string name)
	{
		name = name.toLower();

		auto busr = m_users.findOne(["name": name]);
		enforce(!busr.isNull(), "The specified user name is not registered.");
		auto ret = new User;
		deserializeBson(ret, busr);
		return ret;
	}

	User getUserByEmail(string email)
	{
		email = email.toLower();

		auto busr = m_users.findOne(["email": email]);
		enforce(!busr.isNull(), "The specified email address is not registered.");
		auto ret = new User;
		deserializeBson(ret, busr);
		return ret;
	}

	void enumerateUsers(int first_user, int max_count, void delegate(ref User usr) del)
	{
		foreach( busr; m_users.find(["query": null, "orderby": ["name": 1]], null, QueryFlags.None, first_user, max_count) ){
			auto usr = deserializeBson!User(busr);
			del(usr);
		}
	}

	long getUserCount()
	{
		return m_users.count(Bson.EmptyObject);
	}

	void deleteUser(BsonObjectID user_id)
	{
		m_users.remove(["_id": user_id]);
	}

	void updateUser(User user)
	{
		validateUser(user);
		enforce(m_settings.useUserNames || user.name == user.email, "User name must equal email address if user names are not used.");

		m_users.update(["_id": user._id], user);
	}
	
	void addGroup(string name, string description)
	{
		enforce(m_groups.findOne(["name": name]).isNull(), "A group with this name already exists.");
		auto grp = new Group;
		grp._id = BsonObjectID.generate();
		grp.name = name;
		grp.description = description;
		m_groups.insert(grp);
	}
}

class User {
	BsonObjectID _id;
	bool active;
	bool banned;
	string name;
	string fullName;
	string email;
	string[] groups;
	string activationCode;
	AuthInfo auth;
	Bson[string] properties;
	
	bool isInGroup(string name) const { return groups.countUntil(name) >= 0; }
}

struct AuthInfo {
	string method = "password";
	string passwordHash;
	string token;
	string secret;
	string info;
}

class Group {
	BsonObjectID _id;
	string name;
	string description;
}

string generateActivationCode()
{
	auto ret = appender!string();
	foreach( i; 0 .. 10 ){
		auto n = cast(char)uniform(0, 62);
		if( n < 26 ) ret.put(cast(char)('a'+n));
		else if( n < 52 ) ret.put(cast(char)('A'+n-26));
		else ret.put(cast(char)('0'+n-52));
	}
	return ret.data();
}
