#ifndef _PASSENGER_APPLICATION_H_
#define _PASSENGER_APPLICATION_H_

#include <boost/shared_ptr.hpp>
#include <boost/function.hpp>
#include <string>

#include <sys/types.h>
#include <unistd.h>
#include <errno.h>
#include <ctime>

#include "MessageChannel.h"
#include "Exceptions.h"
#include "Utils.h"

namespace Passenger {

using namespace std;
using namespace boost;

/**
 * Represents a single Ruby on Rails application instance.
 *
 * @ingroup Support
 */
class Application {
public:
	class Session;
	/** A type for callback functions that are called when a session is closed.
	 * @see Application::connect()
	 */
	typedef function<void (Session &session)> CloseCallback;
	/** Convenient alias for Session smart pointer. */
	typedef shared_ptr<Session> SessionPtr;
	
	/**
	 * Represents the life time of a single request/response pair of a Ruby on Rails
	 * application.
	 *
	 * Session is used to forward a single HTTP request to a Ruby on Rails application.
	 * A Session has two communication channels: one for reading data from
	 * the RoR application, and one for writing data to the RoR application.
	 *
	 * In general, a session object is to be used in the following manner:
	 *
	 *  -# Convert the HTTP request headers into a string, as expected by sendHeaders().
	 *     Then send that string by calling sendHeaders().
	 *  -# In case of a POST of PUT request, send the HTTP request body by calling
	 *     sendBodyBlock(), possibly multiple times.
	 *  -# Close the writer channel since you're now done sending data.
	 *  -# The HTTP response can now be read through the reader channel (getReader()).
	 *  -# When the HTTP response has been read, the session must be closed.
	 *     This is done by destroying the Session object.
	 *
	 * A usage example is shown in Application::connect(). 
	 */
	class Session {
	public:
		virtual ~Session() {}
		
		/**
		 * Send HTTP request headers to the RoR application. The HTTP headers must be
		 * converted into CGI headers, and then encoded into a string that matches this grammar:
		 *
		   @verbatim
		   headers ::= header*
		   header ::= name NUL value NUL
		   name ::= notnull+
		   value ::= notnull+
		   notnull ::= "\x01" | "\x02" | "\x02" | ... | "\xFF"
		   NUL = "\x00"
		   @endverbatim
		 *
		 * This method should be the first one to be called during the lifetime of a Session
		 * object. Otherwise strange things may happen.
		 *
		 * @param headers The HTTP request headers, converted into CGI headers and encoded as
		 *                a string, according to the description.
		 * @param size The size, in bytes, of <tt>headers</tt>.
		 * @pre headers != NULL
		 * @throws IOException The writer channel has already been closed.
		 * @throws SystemException Something went wrong during writing.
		 */
		virtual void sendHeaders(const char *headers, unsigned int size) {
			int writer = getWriter();
			if (writer == -1) {
				throw IOException("Cannot write headers to the request handler because the writer channel has already been closed.");
			}
			try {
				MessageChannel(writer).writeScalar(headers, size);
			} catch (const SystemException &e) {
				throw SystemException("An error occured while writing headers to the request handler", e.code());
			}
		}
		
		/**
		 * Convenience shortcut for sendHeaders(const char *, unsigned int)
		 * @param headers
		 * @throws IOException The writer channel has already been closed.
		 * @throws SystemException Something went wrong during writing.
		 */
		virtual void sendHeaders(const string &headers) {
			sendHeaders(headers.c_str(), headers.size());
		}
		
		/**
		 * Send a chunk of HTTP request body data to the RoR application.
		 * You can call this method as many times as is required to transfer
		 * the entire HTTP request body.
		 *
		 * This method should only be called after a sendHeaders(). Otherwise
		 * strange things may happen.
		 *
		 * @param block A block of HTTP request body data to send.
		 * @param size The size, in bytes, of <tt>block</tt>.
		 * @throws IOException The writer channel has already been closed.
		 * @throws SystemException Something went wrong during writing.
		 */
		virtual void sendBodyBlock(const char *block, unsigned int size) {
			int writer = getWriter();
			if (writer == -1) {
				throw IOException("Cannot write request body block to the request handler because the writer channel has already been closed.");
			}
			try {
				MessageChannel(writer).writeRaw(block, size);
			} catch (const SystemException &e) {
				throw SystemException("An error occured while request body to the request handler", e.code());
			}
		}
		
		/**
		 * Get the reader channel's file descriptor.
		 *
		 * @pre The reader channel has not been closed.
		 */
		virtual int getReader() = 0;
		
		/**
		 * Close the reader channel. This method may be safely called multiple times.
		 */
		virtual void closeReader() = 0;
		
		/**
		 * Get the writer channel's file descriptor. You should rarely have to
		 * use this directly. One should only use sendHeaders() and sendBodyBlock()
		 * whenever possible.
		 *
		 * @pre The writer channel has not been closed.
		 */
		virtual int getWriter() = 0;
		
		/**
		 * Close the writer channel. This method may be safely called multiple times.
		 */
		virtual void closeWriter() = 0;
	};

private:
	/**
	 * A structure containing data that both StandardSession and Application
	 * may access. Since Application and StandardSession may have different
	 * life times (i.e. one can be destroyed before the other), they both
	 * have a smart pointer referencing a SharedData structure. Only
	 * when both the StandardSession and the Application object have been
	 * destroyed, will the SharedData object be destroyed as well.
	 */
	struct SharedData {
		unsigned int sessions;
	};
	
	typedef shared_ptr<SharedData> SharedDataPtr;

	/**
	 * A "standard" implementation of Session.
	 */
	class StandardSession: public Session {
	protected:
		SharedDataPtr data;
		CloseCallback closeCallback;
		int reader;
		int writer;
		
	public:
		StandardSession(SharedDataPtr data, const CloseCallback &closeCallback, int reader, int writer) {
			this->data = data;
			this->closeCallback = closeCallback;
			data->sessions++;
			this->reader = reader;
			this->writer = writer;
		}
	
		virtual ~StandardSession() {
			data->sessions--;
			closeReader();
			closeWriter();
			closeCallback(*this);
		}
		
		virtual int getReader() {
			return reader;
		}
		
		virtual void closeReader() {
			if (reader != -1) {
				close(reader);
				reader = -1;
			}
		}
		
		virtual int getWriter() {
			return writer;
		}
		
		virtual void closeWriter() {
			if (writer != -1) {
				close(writer);
				writer = -1;
			}
		}
	};

	string appRoot;
	pid_t pid;
	int listenSocket;
	time_t lastUsed;
	SharedDataPtr data;

public:
	/**
	 * Construct a new Application object.
	 *
	 * @param theAppRoot The application root of a RoR application, i.e. the folder that
	 *             contains 'app/', 'public/', 'config/', etc. This must be a valid directory,
	 *             but the path does not have to be absolute.
	 * @param pid The process ID of this application instance.
	 * @param listenSocket The listener socket of this application instance.
	 * @post getAppRoot() == theAppRoot && getPid() == pid
	 */
	Application(const string &theAppRoot, pid_t pid, int listenSocket) {
		appRoot = theAppRoot;
		this->pid = pid;
		this->listenSocket = listenSocket;
		lastUsed = time(NULL);
		this->data = ptr(new SharedData());
		this->data->sessions = 0;
		P_TRACE("Application " << this << ": created.");
	}
	
	virtual ~Application() {
		close(listenSocket);
		P_TRACE("Application " << this << ": destroyed.");
	}
	
	/**
	 * Returns the application root for this RoR application. See the constructor
	 * for information about the application root.
	 */
	string getAppRoot() const {
		return appRoot;
	}
	
	/**
	 * Returns the process ID of this application instance.
	 */
	pid_t getPid() const {
		return pid;
	}
	
	/**
	 * Connect to this application instance with the purpose of sending
	 * a request to the application. Once connected, a new session will
	 * be opened. This session represents the life time of a single
	 * request/response pair, and can be used to send the request
	 * data to the application instance, as well as receiving the response
	 * data.
	 *
	 * The use of connect() is demonstrated in the following example.
	 * @code
	 *   // Connect to the application and get the newly opened session.
	 *   Application::SessionPtr session(app->connect("/home/webapps/foo"));
	 *   
	 *   // Send the request headers and request body data.
	 *   session->sendHeaders(...);
	 *   session->sendBodyBlock(...);
	 *   // Done sending data, so we close the writer channel.
	 *   session->closeWriter();
	 *
	 *   // Now read the HTTP response.
	 *   string responseData = readAllDataFromSocket(session->getReader());
	 *   // Done reading data, so we close the reader channel.
	 *   session->closeReader();
	 *
	 *   // This session has now finished, so we close the session by resetting
	 *   // the smart pointer to NULL (thereby destroying the Session object).
	 *   session.reset();
	 *
	 *   // We can connect to an Application multiple times. Just make sure
	 *   // the previous session is closed.
	 *   session = app->connect("/home/webapps/bar")
	 * @endcode
	 *
	 * Note that a RoR application instance can only process one
	 * request at the same time, and thus only one session at the same time.
	 * You <b>must</b> close a session when you no longer need if. You you
	 * call connect() without having properly closed a previous session,
	 * you might cause a deadlock because the application instance may be
	 * waiting for you to close the previous session.
	 *
	 * @return A smart pointer to a Session object, which represents the created session.
	 * @param closeCallback A function which will be called when the session has been closed.
	 * @post this->getSessions() == old->getSessions() + 1
	 * @throws SystemException Something went wrong during the connection process.
	 * @throws IOException Something went wrong during the connection process.
	 */
	SessionPtr connect(const CloseCallback &closeCallback) const {
		int ret;
		do {
			ret = write(listenSocket, "", 1);
		} while ((ret == -1 && errno == EINTR) || ret == 0);
		if (ret == -1) {
			throw SystemException("Cannot request a new session from the request handler", errno);
		}
		
		try {
			MessageChannel channel(listenSocket);
			int reader = channel.readFileDescriptor();
			int writer = channel.readFileDescriptor();
			return ptr(new StandardSession(data, closeCallback, reader, writer));
		} catch (const SystemException &e) {
			throw SystemException("Cannot receive one of the session file descriptors from the request handler", e.code());
		} catch (const IOException &e) {
			string message("Cannot receive one of the session file descriptors from the request handler");
			message.append(e.what());
			throw IOException(message);
		}
	}
	
	/**
	 * Get the number of currently opened sessions.
	 */
	unsigned int getSessions() const {
		return data->sessions;
	}
	
	/**
	 * Returns the last value set by setLastUsed(). This represents the time
	 * at which this application object was last used.
	 *
	 * This is used by StandardApplicationPool's cleaner thread to determine which
	 * Application objects have been idle for too long and need to be cleaned
	 * up. Thus, outside StandardApplicationPool, one should never have to call this
	 * method directly.
	 */
	time_t getLastUsed() const {
		return lastUsed;
	}
	
	/**
	 * Set the time at which this Application object was last used. See getLastUsed()
	 * for information.
	 *
	 * @param time The time.
	 * @post getLastUsed() == time
	 */
	void setLastUsed(time_t time) {
		lastUsed = time;
	}
};

/** Convenient alias for Application smart pointer. */
typedef shared_ptr<Application> ApplicationPtr;

} // namespace Passenger

#endif /* _PASSENGER_APPLICATION_H_ */